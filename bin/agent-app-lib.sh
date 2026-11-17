# shellcheck shell=bash
# The agent's own GitHub identity: a GitHub App the owner registers once (`guardrails agent create`). In a kit
# repository where the App is installed, the agent's gh and git run with a one-hour installation token of that
# App instead of the owner's login, so its PRs are authored by the App's bot and the owner approves them with
# ordinary GitHub reviews. Sourced by bin/guardrails and hooks-global/agent-identity.sh; needs lib.sh (die).
#
# Files under agent_dir (mode 700):
#   app.json         {id, client_id, slug, owner, html_url}: public facts about the App
#   private-key.pem  the App's private key (mode 600); whoever holds it acts as the agent
#   sessions/<owner>__<repo>/hosts.yml  a gh config holding the current token for one repository
# Bash 3.2 compatible.

agent_dir() {
  printf '%s\n' "$HOME/.config/agent-guardrails/agent"
}

# Permissions the App is created with and must not exceed: no workflows (so the agent cannot change CI), no
# administration, statuses, checks or issues.
agent_permissions_json() {
  printf '%s\n' '{"contents":"write","metadata":"read","pull_requests":"write"}'
}

# Base64url without padding, of stdin.
b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# Prints an RS256 JWT for the App. Arguments: client ID (the issuer), private key file, now (epoch seconds).
# Valid from 60 s before now (clock drift) for 9 minutes; GitHub accepts at most 10.
app_jwt() {
  local issuer=$1 key=$2 now=$3 header payload signature
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)
  payload=$(jq -c -n --arg iss "$issuer" --argjson iat $((now - 60)) --argjson exp $((now + 540)) \
    '{iat: $iat, exp: $exp, iss: $iss}' | tr -d '\n' | b64url)
  signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" -binary | b64url)
  printf '%s.%s.%s\n' "$header" "$payload" "$signature"
}

# The App manifest for the registration flow. Arguments: App name, homepage URL.
app_manifest() {
  jq -c -n --arg name "$1" --arg url "$2" --argjson permissions "$(agent_permissions_json)" '{
    name: $name, url: $url, public: false,
    description: "Identity of AI coding agents under agent-guardrails. Humans review and approve its pull requests.",
    default_permissions: $permissions, default_events: []}'
}

# The App name for an owner: at most 34 characters, as GitHub requires.
app_name() {
  local name="guardrails-agent-$1"
  printf '%s\n' "${name:0:34}"
}

# Prints one line per problem with an installation (GET /repos/{owner}/{repo}/installation), nothing when it
# is safe: installed on selected repositories only, and no permission beyond agent_permissions_json.
installation_problems() {
  jq -r --argjson allowed "$(agent_permissions_json)" '
    (if .repository_selection != "selected" then
       "the App is installed on all repositories of \(.account.login); install it on selected repositories only"
     else empty end),
    (.permissions | to_entries[]
     | select(($allowed[.key] // "none") as $max
              | ({none: 0, read: 1, write: 2, admin: 3}[.value] // 3) > ({none: 0, read: 1, write: 2}[$max]))
     | "the App has \(.key): \(.value), more than the agent needs; remove it in the App settings")'
}

# The gh hosts.yml that makes gh (and git through `gh auth git-credential`) use a token.
# Arguments: token, bot login.
gh_hosts_yml() {
  printf 'github.com:\n    oauth_token: %s\n    user: %s\n    git_protocol: https\n' "$1" "$2"
}

# Calls the GitHub REST API with an App JWT or an installation token, retrying the same call with backoff on
# network errors and 5xx answers (a warning per failed attempt). Prints the HTTP status on the first line and
# the body after it. Arguments: method, path, bearer token, JSON body ("" for none).
github_app_call() {
  local method=$1 path=$2 bearer=$3 body=$4 attempt=1 out status
  local args=(-sS -w '\n%{http_code}' -X "$method" "https://api.github.com$path"
    -H "Authorization: Bearer $bearer" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28')
  [[ -z $body ]] || args+=(--data "$body")
  while :; do
    out=$(curl "${args[@]}" 2>&1) || out=$'\n000'
    status=${out##*$'\n'}
    if [[ ($status == 000 || $status == 5*) && $attempt -lt 3 ]]; then
      printf 'warning: GitHub API %s %s failed (attempt %d of 3, status %s), retrying in %ds\n' \
        "$method" "$path" "$attempt" "$status" $((attempt * 2)) >&2
      sleep $((attempt * 2))
      attempt=$((attempt + 1))
      continue
    fi
    printf '%s\n%s\n' "$status" "${out%$'\n'*}"
    return 0
  done
}

# Like github_app_call, but prints only the body and dies with method, path, status and body unless the
# answer is 2xx.
github_app_api() {
  local out status
  out=$(github_app_call "$@")
  status=${out%%$'\n'*}
  [[ $status == 2* ]] || die "GitHub API $1 $2 answered $status: $(sed 1d <<<"$out" | tr '\n' ' ' | cut -c1-400)"
  sed 1d <<<"$out"
}

# Succeeds when the agent App is registered on this machine.
agent_app_registered() {
  local dir
  dir=$(agent_dir)
  [[ -f $dir/app.json && -f $dir/private-key.pem ]]
}

# Prints the installation JSON of the agent App for owner/repo, or nothing when the App is not installed there.
agent_installation() {
  local repo=$1 dir jwt out status
  dir=$(agent_dir)
  jwt=$(app_jwt "$(jq -r .client_id "$dir/app.json")" "$dir/private-key.pem" "$(date +%s)")
  out=$(github_app_call GET "/repos/$repo/installation" "$jwt" "")
  status=${out%%$'\n'*}
  case $status in
    200) sed 1d <<<"$out" ;;
    404) ;;
    *) die "GitHub answered $status for the agent App installation on $repo: $(sed 1d <<<"$out" | tr '\n' ' ' | cut -c1-400)" ;;
  esac
}

# Writes a fresh token for one repository into its gh config directory and prints that directory. The token
# is limited to that repository and to the agent's permissions. Arguments: owner/repo, installation ID.
agent_session_token() {
  local repo=$1 installation=$2 dir session jwt request token slug
  dir=$(agent_dir)
  session="$dir/sessions/${repo/\//__}"
  jwt=$(app_jwt "$(jq -r .client_id "$dir/app.json")" "$dir/private-key.pem" "$(date +%s)")
  request=$(jq -c -n --arg name "${repo#*/}" --argjson permissions "$(agent_permissions_json)" \
    '{repositories: [$name], permissions: $permissions}')
  token=$(github_app_api POST "/app/installations/$installation/access_tokens" "$jwt" "$request" | jq -r .token)
  [[ -n $token && $token != null ]] || die "GitHub returned no installation token for $repo"
  slug=$(jq -r .slug "$dir/app.json")
  (
    umask 077
    mkdir -p "$session"
    gh_hosts_yml "$token" "${slug}[bot]" >"$session/hosts.yml.new"
    mv "$session/hosts.yml.new" "$session/hosts.yml"
  )
  printf '%s\n' "$session"
}

# The shell exports that make a Claude Code session use a gh config directory: gh reads its token there, git
# asks gh for HTTPS credentials (every other helper dropped), and SSH remotes are rewritten to HTTPS.
# Arguments: gh config directory, path of the gh executable.
agent_env_exports() {
  local config=$1 gh_path=$2
  printf 'export GH_CONFIG_DIR=%q\n' "$config"
  printf 'export GIT_CONFIG_COUNT=4\n'
  printf 'export GIT_CONFIG_KEY_0=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_0=git@github.com:\n'
  printf 'export GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf GIT_CONFIG_VALUE_1=ssh://git@github.com/\n'
  # An empty helper value drops every helper configured before it (osxkeychain, stored passwords).
  printf "export GIT_CONFIG_KEY_2=credential.https://github.com.helper GIT_CONFIG_VALUE_2=''\n"
  printf 'export GIT_CONFIG_KEY_3=credential.https://github.com.helper GIT_CONFIG_VALUE_3=%q\n' "!$gh_path auth git-credential"
}

# Prints owner/repo of every repository the agent App is installed on, one per line (lowercase); nothing when
# no App is registered here.
agent_installed_repos() {
  local dir jwt id token
  agent_app_registered || return 0
  dir=$(agent_dir)
  jwt=$(app_jwt "$(jq -r .client_id "$dir/app.json")" "$dir/private-key.pem" "$(date +%s)")
  for id in $(github_app_api GET /app/installations "$jwt" "" | jq -r '.[].id'); do
    token=$(github_app_api POST "/app/installations/$id/access_tokens" "$jwt" '{"permissions":{"metadata":"read"}}' | jq -r .token)
    github_app_api GET "/installation/repositories?per_page=100" "$token" "" | jq -r '.repositories[].full_name | ascii_downcase'
  done
}
