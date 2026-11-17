# shellcheck shell=bash
# Shared by approve-head and revoke-head. Source it; do not execute it.

# Prints "<owner/repo> <number>" for a PR given as a GitHub URL (works from any directory) or as a
# number (the repository of the current directory). Callers: `target=$(pr_target "$1") || exit 1`.
pr_target() {
  local ref=$1 repo
  if [[ $ref =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)(/.*)?$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ $ref =~ ^[0-9]+$ ]]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner) ||
      die "PR number $ref needs a GitHub repository in the current directory; pass the PR link instead"
    printf '%s %s\n' "$repo" "$ref"
  else
    die "expected a PR link (https://github.com/<owner>/<repo>/pull/<n>) or a PR number, got: $ref"
  fi
}
