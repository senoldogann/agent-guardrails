# shellcheck shell=bash
# Shared by the global hooks and bin/guardrails. Source it; do not execute it.

# The owner's list of enforced repositories ("owner/repo" per line), written only by `guardrails on/off`.
guardrails_registry() {
  printf '%s\n' "$HOME/.config/agent-guardrails/repos"
}

# Prints "owner/repo" of a directory's GitHub origin remote; nothing when there is none.
origin_repo() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 0
  [[ $url == *github.com[:/]* ]] || return 0
  sed -E 's#^.*github\.com[:/]##; s#\.git$##; s#/$##' <<<"$url"
}

# An existing but unreadable list counts as listing every repository: the guard fails closed.
is_registered_repo() {
  local registry
  registry=$(guardrails_registry)
  [[ -e $registry && ! -r $registry ]] && return 0
  [[ -n $1 && -f $registry ]] && grep -Fxi -- "$1" "$registry" >/dev/null
}

# Succeeds when the directory belongs to a git repository that uses the agent-guardrails kit: its root
# has .agent/bin/ci-guard, or its origin is an enforced repository (so deleting .agent/ locally does not
# switch the guard off). Outside such repositories the global hooks stay out of the way. Only git's own "not a git
# repository" says a directory is outside: any other failure of git (a broken install, a dubious owner) counts as a
# kit repository, so the guards fail closed.
is_kit_project() {
  local dir=$1 root
  [[ -n $dir && -d $dir ]] || return 1
  if ! root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null); then
    case $(LC_ALL=C git -C "$dir" rev-parse --show-toplevel 2>&1 >/dev/null) in
      *"not a git repository"*) return 1 ;;
      *) return 0 ;;
    esac
  fi
  [[ -x "$root/.agent/bin/ci-guard" ]] && return 0
  is_registered_repo "$(origin_repo "$root")"
}

# Succeeds when the text names an enforced repository ("owner/repo"), wherever the command runs.
mentions_registered_repo() {
  local text=$1 registry repo
  registry=$(guardrails_registry)
  [[ -e $registry && ! -r $registry ]] && return 0
  [[ -f $registry ]] || return 1
  while IFS= read -r repo; do
    [[ -n $repo ]] || continue
    grep -Fi -- "$repo" <<<"$text" >/dev/null && return 0
  done <"$registry"
  return 1
}
