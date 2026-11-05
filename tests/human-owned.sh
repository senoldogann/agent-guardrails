#!/usr/bin/env bash
# Table tests for is_human_owned: paths agents may never get write-allowed.
set -euo pipefail
kit=$(cd "$(dirname "$0")/.." && pwd -P)
source "$kit/skills/guardrails-init/template/.agent/bin/lib.sh"

failed=0
check() {
  local want=$1 path=$2 got=no
  if is_human_owned "$path"; then got=yes; fi
  if [[ $got == "$want" ]]; then printf '  ok   %s %s\n' "$want" "$path"; else
    printf '  FAIL %s: want %s, got %s\n' "$path" "$want" "$got"
    failed=$((failed + 1))
  fi
}

echo "is_human_owned"
check yes .cargo/config.toml
check yes .stryker-tmp/sandbox/src/x.ts
check yes src/.hidden/helper.ts
check yes .github/workflows/ci.yml
check yes stryker.config.mjs
check yes .cargo/mutants.toml
check yes src/domain/discount.test.ts
check yes specs/DEMO-1/write-allow
check no src/domain/discount.ts
check no src/shared/math.ts
[[ $failed -eq 0 ]]
