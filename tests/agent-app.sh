#!/usr/bin/env bash
# Offline tests for bin/agent-app-lib.sh: the App JWT verifies with the App's public key and carries the
# right claims, the manifest asks only for the agent's permissions, unsafe installations are reported, and
# the gh config written for a token has the expected shape.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"
source "$kit/bin/agent-app-lib.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
passed=0
failed=0
expect_eq() {
  if [[ $2 == "$3" ]]; then passed=$((passed + 1)); else
    failed=$((failed + 1))
    printf '  FAIL %s: want [%s] got [%s]\n' "$1" "$3" "$2"
  fi
}
b64url_decode() {
  local s
  s=$(tr -- '-_' '+/' <<<"$1")
  while ((${#s} % 4)); do s+="="; done
  openssl base64 -d -A <<<"$s"
}

echo "agent-app"
openssl genrsa -out "$work/key.pem" 2048 2>/dev/null
openssl rsa -in "$work/key.pem" -pubout -out "$work/pub.pem" 2>/dev/null
jwt=$(app_jwt Iv23abc "$work/key.pem" 1000000)
IFS=. read -r header payload signature <<<"$jwt"
expect_eq "JWT header" "$(b64url_decode "$header")" '{"alg":"RS256","typ":"JWT"}'
expect_eq "JWT claims" "$(b64url_decode "$payload" | jq -c .)" '{"iat":999940,"exp":1000540,"iss":"Iv23abc"}'
b64url_decode "$signature" >"$work/sig.bin"
verified=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -verify "$work/pub.pem" -signature "$work/sig.bin")
expect_eq "JWT signature verifies with the public key" "$verified" "Verified OK"
expect_eq "no padding or URL-unsafe characters" "$(grep -c '[=+/]' <<<"$jwt" || true)" 0

expect_eq "short name kept" "$(app_name acme)" "guardrails-agent-acme"
expect_eq "long name cut to 34" "$(app_name a-very-long-organization-name-x)" "guardrails-agent-a-very-long-organ"
expect_eq "long name length" "$(app_name a-very-long-organization-name-x | tr -d '\n' | wc -c | tr -d ' ')" 34
manifest=$(app_manifest guardrails-agent-acme https://github.com/acme)
expect_eq "manifest permissions" "$(jq -c .default_permissions <<<"$manifest")" \
  '{"contents":"write","metadata":"read","pull_requests":"write"}'
expect_eq "manifest is private and has no events" "$(jq -c '[.public, .default_events]' <<<"$manifest")" '[false,[]]'

installation() {
  jq -n -c --arg selection "$1" --argjson permissions "$2" \
    '{repository_selection: $selection, account: {login: "acme"}, permissions: $permissions}'
}
safe='{"contents":"write","metadata":"read","pull_requests":"write"}'
expect_eq "selected repos with the agent's permissions is safe" "$(installation selected "$safe" | installation_problems)" ""
expect_eq "fewer permissions are safe" "$(installation selected '{"metadata":"read"}' | installation_problems)" ""
expect_eq "all repositories is reported" "$(installation all "$safe" | installation_problems)" \
  "the App is installed on all repositories of acme; install it on selected repositories only"
expect_eq "workflows permission is reported" \
  "$(installation selected '{"contents":"write","workflows":"write"}' | installation_problems)" \
  "the App has workflows: write, more than the agent needs; remove it in the App settings"
expect_eq "admin on an allowed permission is reported" \
  "$(installation selected '{"contents":"admin"}' | installation_problems)" \
  "the App has contents: admin, more than the agent needs; remove it in the App settings"
expect_eq "reading an extra permission is reported" \
  "$(installation selected '{"statuses":"read"}' | installation_problems)" \
  "the App has statuses: read, more than the agent needs; remove it in the App settings"

expect_eq "gh hosts.yml" "$(gh_hosts_yml ghs_x 'bot[bot]')" $'github.com:\n    oauth_token: ghs_x\n    user: bot[bot]\n    git_protocol: https'

# The session exports, as git sees them: SSH remotes become HTTPS and gh is the only GitHub credential helper.
(
  export HOME="$work/git-home"
  mkdir -p "$HOME"
  # The owner's stored password would answer first without the reset.
  git config --global credential.helper store
  printf 'https://owner:owner-token@github.com\n' >"$HOME/.git-credentials"
  printf '#!/usr/bin/env bash\n[[ "$*" == "auth git-credential get" ]] && printf "username=x-access-token\\npassword=bot-token\\n"\n' \
    >"$work/fake-gh"
  chmod +x "$work/fake-gh"
  eval "$(agent_env_exports "$work/agent gh" "$work/fake-gh")"
  expect_eq "gh config directory" "$GH_CONFIG_DIR" "$work/agent gh"
  expect_eq "SSH remote rewritten" "$(git ls-remote --get-url git@github.com:acme/shop.git)" "https://github.com/acme/shop.git"
  expect_eq "SSH URL rewritten" "$(git ls-remote --get-url ssh://git@github.com/acme/shop.git)" "https://github.com/acme/shop.git"
  expect_eq "git gets the bot token, not the owner's stored password" \
    "$(printf 'protocol=https\nhost=github.com\npath=acme/shop.git\n\n' | git credential fill | grep '^password=')" \
    "password=bot-token"
  printf '%s %s\n' "$passed" "$failed" >"$work/counts"
)
read -r passed failed <"$work/counts"

# Without a registered App the identity hook leaves a kit repository's session alone.
kit_repo="$work/kit-repo"
mkdir -p "$kit_repo/.agent/bin"
git -C "$kit_repo" init -q
printf '#!/usr/bin/env bash\n' >"$kit_repo/.agent/bin/ci-guard"
chmod +x "$kit_repo/.agent/bin/ci-guard"
mkdir -p "$work/empty-home"
identity_out=$(jq -n --arg d "$kit_repo" '{cwd: $d, hook_event_name: "SessionStart"}' |
  HOME="$work/empty-home" CLAUDE_ENV_FILE="$work/env-file" "$kit/hooks-global/agent-identity.sh" 2>&1) &&
  identity_status=0 || identity_status=$?
expect_eq "no App: no output, no exports" "$identity_status [$identity_out] $(cat "$work/env-file" 2>/dev/null | wc -l | tr -d ' ')" "0 [] 0"

# The registration flow without a browser: the local page posts the manifest with this server as the redirect
# and the state GitHub must echo; the callback with that state prints the code, another state fails.
flow() {
  BROWSER=true python3 -I "$kit/scripts/app-manifest-flow.py" "$manifest" https://github.example/settings/apps/new \
    >"$work/flow.out" 2>"$work/flow.err" &
  flow_pid=$!
  port=""
  for _ in $(seq 50); do
    port=$(sed -nE 's#.*http://127\.0\.0\.1:([0-9]+)/.*#\1#p' "$work/flow.err")
    [[ -z $port ]] || break
    sleep 0.1
  done
  page=$(curl -sS "http://127.0.0.1:$port/")
  state=$(sed -nE 's/.*state=([A-Za-z0-9_-]+).*/\1/p' <<<"$page")
}
flow
expect_eq "the page posts the manifest to GitHub" "$(grep -o 'action=.https://github.example/settings/apps/new' <<<"$page" | head -1)" \
  "action='https://github.example/settings/apps/new"
expect_eq "the manifest redirects to this server" \
  "$(grep -o "http://127.0.0.1:$port/callback" <<<"$page" | head -1)" "http://127.0.0.1:$port/callback"
curl -sS "http://127.0.0.1:$port/callback?code=abc_123&state=$state" >/dev/null
wait "$flow_pid" && flow_status=0 || flow_status=$?
expect_eq "the right state yields the code" "$flow_status $(cat "$work/flow.out")" "0 abc_123"
flow
curl -sS "http://127.0.0.1:$port/callback?code=abc_123&state=forged" >/dev/null
wait "$flow_pid" && flow_status=0 || flow_status=$?
expect_eq "another state fails without a code" "$flow_status $(cat "$work/flow.out")" "1 "

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
