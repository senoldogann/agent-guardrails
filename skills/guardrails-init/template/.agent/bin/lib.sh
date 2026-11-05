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
  awk 'NF > 0 && $0 !~ /^[[:space:]]*#/' "$1"
}

# Succeeds when a repo-relative path is human-owned: guardrails, agent context, CI, specs, tests,
# build/lint/test configuration, manifests, lockfiles and dotfiles. Agents may change such paths only
# with human review; they can never be write-allowed.
is_human_owned() {
  local path=$1 base
  base=${path##*/}
  case $path in
    .agent/* | .claude/* | .github/* | specs/* | docs/CODEOWNERS | CODEOWNERS) return 0 ;;
    tests/* | */tests/* | test/* | */test/* | Tests/* | */Tests/* | */__tests__/* | __tests__/*) return 0 ;;
  esac
  case $base in
    .*) return 0 ;;
    AGENTS.md | CLAUDE.md | Makefile | GNUmakefile | makefile | *.mk) return 0 ;;
    *.test.* | *.spec.* | *_test.* | *_tests.* | test_*.py | *Tests.swift | *Test.swift) return 0 ;;
    conftest.py | sitecustomize.py | usercustomize.py | *.pth | setup.py | setup.cfg | tox.ini | pytest.ini) return 0 ;;
    pyproject.toml | uv.lock | requirements*.txt | ruff.toml | pyrightconfig.json | mypy.ini) return 0 ;;
    package.json | pnpm-lock.yaml | package-lock.json | yarn.lock | pnpm-workspace.yaml) return 0 ;;
    tsconfig*.json | jsconfig*.json | biome.json | biome.jsonc | *.grit) return 0 ;;
    vite.config.* | vitest.config.* | vitest.workspace.* | vitest.setup.* | *.setup.ts | *.setup.js) return 0 ;;
    Cargo.toml | Cargo.lock | build.rs | clippy.toml | rustfmt.toml | rust-toolchain | rust-toolchain.toml | nextest.toml) return 0 ;;
    Package.swift | Package.resolved | *.xcconfig | *.pbxproj | *.xcscheme | *.entitlements | Info.plist) return 0 ;;
    Dockerfile | *.dockerfile | docker-compose*.yml | compose*.yml) return 0 ;;
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
