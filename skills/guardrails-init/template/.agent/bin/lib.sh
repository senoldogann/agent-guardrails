# shellcheck shell=bash
# Shared helpers for .agent/bin scripts. Source it; do not execute it.
# Bash 3.2 compatible (macOS default): no mapfile, no associative arrays.

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

cd_project_root() {
  cd "$(git rev-parse --show-toplevel)" || exit 1
}

require_args() {
  local expected=$1 actual=$2 usage=$3
  [[ $actual -eq $expected ]] || die "usage: $usage"
}

# Prints "path" lines from a `shasum -a 256` file (strips the 64-char hash and two spaces).
lock_paths() {
  sed -E 's/^[0-9a-f]{64}  //' "$1"
}

# Prints non-empty, non-comment lines of a pattern/path list file.
list_entries() {
  entry_lines <"$1"
}

# Prints the non-empty, non-comment lines of a pattern/path list on stdin.
entry_lines() {
  awk 'NF > 0 && $0 !~ /^[[:space:]]*#/'
}

# Prints its argument without control characters (newlines kept) and backticks, so a name an agent wrote cannot
# forge lines or break a Markdown fence in the guard's output.
printable() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\011\013-\037\140\177'
}

# A spec lock (specs/<TICKET>/spec.lock) is a `shasum -a 256` manifest: exactly the ticket's spec metadata below
# plus every entry of its locked-files, once each. Checksums alone prove nothing about a manifest that leaves a
# protected file out, so spec-lock, lock-verify and both CI guards check its structure with these functions.

# Prints the spec metadata every spec lock covers. Argument: the ticket's directory (specs/<TICKET>).
spec_lock_metadata() {
  printf '%s\n' "$1/locked-files" "$1/write-allow" "$1/acceptance-criteria.md" "$1/OPEN_QUESTIONS.md" "$1/tests.lock"
}

# Succeeds for a plain repository-relative path: not empty, not absolute, no empty, "." or ".." component and
# no trailing slash, so it cannot point outside the repository or name one file two ways. Control characters,
# backslashes and backticks are refused too: shasum escapes names with a backslash or newline, and the others
# could forge lines in the guard's output. So is whitespace at either end of a component, which would make a
# look-alike twin of a locked file ("tests/a.test.ts ").
is_repo_path() {
  local path=$1
  case $path in
    *[[:cntrl:]]* | *\\* | *\`*) return 1 ;;
  esac
  case "/$path/" in
    *//* | */./* | */../* | */[[:space:]]* | *[[:space:]]/*) return 1 ;;
  esac
  return 0
}

# Prints a path in double quotes with every byte outside printable ASCII, and the quote, backslash and backtick, as
# an octal escape (as git quotes paths), so look-alike names (a non-breaking or zero-width space, another Unicode
# form of a letter) read differently in the owner's summary.
quoted_path() {
  local LC_ALL=C
  local path=$1 out="" char code i
  for ((i = 0; i < ${#path}; i++)); do
    char=${path:i:1}
    case $char in
      '"' | \\ | '`') ;;
      [[:print:]])
        out+=$char
        continue
        ;;
    esac
    code=$(printf '%d' "'$char")
    # Bash reads a byte above 127 as a negative char on some platforms.
    [[ $code -ge 0 ]] || code=$((code + 256))
    out+=$(printf '\\%03o' "$code")
  done
  printf '"%s"\n' "$out"
}

# Reads a ticket's locked-files on stdin and prints one problem per line: no entries, an entry that is not a plain
# repository-relative path, one listed twice, or one that is the ticket's own spec metadata or lock (spec-lock
# covers those itself). Argument: the ticket's directory.
locked_files_problems() {
  local dir=$1 entries path seen="" own
  entries=$(entry_lines)
  [[ -n $entries ]] || {
    printf '%s/locked-files lists no files\n' "$dir"
    return 0
  }
  own=$(spec_lock_metadata "$dir"; printf '%s/spec.lock\n' "$dir")
  while IFS= read -r path; do
    if ! is_repo_path "$path"; then
      printf "%s/locked-files lists '%s', which is not a plain repository-relative path\n" "$dir" "$(printable "$path")"
    elif grep -Fx -- "$path" <<<"$seen" >/dev/null; then
      printf '%s/locked-files lists %s twice\n' "$dir" "$path"
    elif grep -Fx -- "$path" <<<"$own" >/dev/null; then
      printf '%s/locked-files lists %s, which the spec lock covers as metadata already\n' "$dir" "$path"
    fi
    seen+="$path"$'\n'
  done <<<"$entries"
}

# Prints the path of every well-formed line of a spec lock read on stdin.
manifest_paths() {
  sed -nE 's/^[0-9a-f]{64}  (.+)$/\1/p'
}

# Reads a spec lock on stdin and prints one problem per line: empty, a line that is not "<sha256>  <path>", a path
# that is not plain and repository-relative, a path listed twice, an expected path it does not cover, or a path
# nobody declared. Arguments: the lock's path, the ticket's directory, the paths it must cover (one per line).
manifest_problems() {
  local lock=$1 dir=$2 expected=$3 body line path n=0 seen="" pattern='^[0-9a-f]{64}  (.+)$'
  body=$(cat)
  if [[ -z $body ]]; then
    printf 'spec lock %s is empty\n' "$lock"
    return 0
  fi
  while IFS= read -r line; do
    n=$((n + 1))
    if [[ ! $line =~ $pattern ]]; then
      printf "spec lock %s line %s is not '<sha256>  <path>' as spec-lock writes it\n" "$lock" "$n"
      continue
    fi
    path=${BASH_REMATCH[1]}
    if ! is_repo_path "$path"; then
      printf "spec lock %s line %s names '%s', which is not a plain repository-relative path\n" "$lock" "$n" "$(printable "$path")"
    elif grep -Fx -- "$path" <<<"$seen" >/dev/null; then
      printf 'spec lock %s lists %s twice\n' "$lock" "$path"
    elif ! grep -Fx -- "$path" <<<"$expected" >/dev/null; then
      printf 'spec lock %s lists %s, which is neither spec metadata nor in %s/locked-files\n' "$lock" "$path" "$dir"
    fi
    seen+="$path"$'\n'
  done <<<"$body"
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    if grep -Fx -- "$path" <<<"$seen" >/dev/null; then continue; fi
    if grep -Fx -- "$path" <(spec_lock_metadata "$dir") >/dev/null; then
      printf 'spec lock %s does not cover %s\n' "$lock" "$path"
    else
      printf 'spec lock %s does not cover %s, which %s/locked-files declares\n' "$lock" "$path" "$dir"
    fi
  done <<<"$expected"
}

# Succeeds when a repo-relative path is human-owned: guardrails, agent context, CI, specs, tests,
# build/lint/test configuration, manifests, lockfiles and dotfiles. Agents may change such paths only
# with human review; they can never be write-allowed. Names are matched without case (see without_case), except
# Swift's test file suffixes, which a source file like Latest.swift shares in lower case.
is_human_owned() {
  case ${1##*/} in
    *Tests.swift | *Test.swift) return 0 ;;
  esac
  without_case human_owned_match "$1"
}

# Succeeds for a test file or a file in a test directory: the human-owned paths the spec phase writes. Matched like
# is_human_owned. Argument: repository-relative path.
is_test_path() {
  case ${1##*/} in
    *Tests.swift | *Test.swift) return 0 ;;
  esac
  without_case test_path_match "$1"
}

# Runs a path matcher with matching that ignores case: macOS's default file system resolves names without case, so
# MAKEFILE or CONFTEST.py there is read as Makefile or conftest.py. Arguments: matcher function, path.
without_case() {
  local status=1 restore=-u
  ! shopt -q nocasematch || restore=-s
  shopt -s nocasematch
  if "$1" "$2"; then status=0; fi
  shopt "$restore" nocasematch
  return "$status"
}

# The patterns of is_test_path. Argument: repository-relative path.
test_path_match() {
  case $1 in
    tests/* | */tests/* | test/* | */test/* | */__tests__/* | __tests__/*) return 0 ;;
  esac
  case ${1##*/} in
    *.test.* | *.spec.* | *_test.* | *_tests.* | test_*.py) return 0 ;;
  esac
  return 1
}

# The patterns of is_human_owned. Argument: repository-relative path.
human_owned_match() {
  local path=$1 base
  base=${path##*/}
  test_path_match "$path" && return 0
  case "/$path" in
    */.*) return 0 ;; # any dot directory or dotfile (.cargo/config.toml, .stryker-tmp/, .github/)
  esac
  case $path in
    specs/* | docs/CODEOWNERS | CODEOWNERS) return 0 ;;
    *.xcodeproj/* | *.xcworkspace/*) return 0 ;;
  esac
  case $base in
    AGENTS.md | CLAUDE.md | Makefile | GNUmakefile | makefile | *.mk | justfile | Taskfile.yml | Taskfile.yaml) return 0 ;;
    lefthook.yml | lefthook.yaml | flake.nix | flake.lock | devbox.json | mise.toml) return 0 ;;
    conftest.py | sitecustomize.py | usercustomize.py | *.pth | setup.py | setup.cfg | tox.ini | pytest.ini) return 0 ;;
    pyproject.toml | uv.lock | uv.toml | requirements*.txt | requirements*.in | constraints*.txt | noxfile.py) return 0 ;;
    poetry.lock | poetry.toml | Pipfile | Pipfile.lock | pdm.lock | pdm.toml | hatch.toml | pixi.toml | pixi.lock) return 0 ;;
    ruff.toml | pyrightconfig.json | mypy.ini | pylintrc) return 0 ;;
    package.json | pnpm-lock.yaml | package-lock.json | npm-shrinkwrap.json | yarn.lock | pnpm-workspace.yaml) return 0 ;;
    bun.lock | bun.lockb | bunfig.toml | deno.json | deno.jsonc | deno.lock | turbo.json | nx.json | lerna.json) return 0 ;;
    tsconfig*.json | jsconfig*.json | biome.json | biome.jsonc | *.grit) return 0 ;;
    vite.config.* | vitest.config.* | vitest.workspace.* | vitest.setup.* | *.setup.ts | *.setup.js) return 0 ;;
    jest.config.* | playwright.config.* | playwright-ct.config.* | cypress.config.* | karma.conf.* | ava.config.*) return 0 ;;
    eslint.config.* | prettier.config.* | stylelint.config.* | babel.config.* | webpack.config.* | rollup.config.*) return 0 ;;
    tsup.config.*) return 0 ;;
    stryker.config.* | stryker.conf.* | mutants.toml | setup.cfg.mutmut | mutmut_config.py) return 0 ;;
    Cargo.toml | Cargo.lock | build.rs | clippy.toml | rustfmt.toml | rust-toolchain | rust-toolchain.toml | nextest.toml) return 0 ;;
    deny.toml) return 0 ;;
    Package.swift | Package@swift*.swift | Package.resolved | *.xcconfig | *.pbxproj | *.xcscheme | *.entitlements) return 0 ;;
    Info.plist | *.xctestplan | *.xcprivacy | *.storekit | project.yml) return 0 ;;
    Podfile | Podfile.lock | Cartfile | Cartfile.resolved | Gemfile | Gemfile.lock | Mintfile) return 0 ;;
    Dockerfile | Containerfile | *.dockerfile | docker-compose*.yml | docker-compose*.yaml | compose*.yml | compose*.yaml) return 0 ;;
  esac
  return 1
}

# Prints a tree hash of HEAD plus every uncommitted (tracked or untracked, not ignored) change,
# without touching the real index. Equal hashes mean identical working trees.
worktree_snapshot() {
  local dir index tree
  dir=$(mktemp -d)
  index="$dir/index"
  GIT_INDEX_FILE=$index git read-tree HEAD
  GIT_INDEX_FILE=$index git add -A
  tree=$(GIT_INDEX_FILE=$index git write-tree)
  rm -rf "$dir"
  printf '%s\n' "$tree"
}

# Prints the number of the open PR for the current branch; nothing when there is none or the origin is
# not on GitHub (local test repositories).
current_pr() {
  local url out
  url=$(git remote get-url origin 2>/dev/null) || return 0
  [[ $url == *github.com[:/]* ]] || return 0
  if out=$(gh pr view --json number,state --jq 'select(.state == "OPEN") | .number' 2>&1); then
    printf '%s' "$out"
  elif grep -i 'no pull requests found' <<<"$out" >/dev/null; then
    return 0
  else
    die "could not look up the PR of this branch: $out"
  fi
}

# Ends a block: removes .agent/blocked and the PR's needs-decision label (also when the block was set in
# another session or checkout), so the owner's `guardrails` inbox stops listing it.
clear_block() {
  local pr
  rm -f .agent/blocked
  pr=$(current_pr)
  [[ -n $pr ]] || return 0
  if gh pr view "$pr" --json labels --jq '.labels[].name' | grep -Fx needs-decision >/dev/null; then
    gh pr edit "$pr" --remove-label needs-decision >/dev/null
  fi
}
