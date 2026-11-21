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
check yes App.xcodeproj/project.pbxproj
check yes App.xcodeproj/project.xcworkspace/contents.xcworkspacedata
check yes App.xctestplan
check yes project.yml
check yes Packages/Core/Package.swift
check yes Packages/Core/Tests/CoreTests/PasswordTests.swift
check no Packages/Core/Sources/Core/Password.swift
check no src/domain/discount.ts
check no src/shared/math.ts
# Names macOS's default file system resolves without case.
check yes MAKEFILE
check yes src/pkg/CONFTEST.py
check yes TESTS/test_rates.py
check yes Pyproject.toml
# Swift's test suffixes keep their case: Latest.swift is source.
check no Sources/App/Latest.swift
check no Sources/App/Contests.swift
# Configuration of tools that run or judge the checks, manifests and lock files.
check yes uv.toml
check yes poetry.lock
check yes Pipfile
check yes noxfile.py
check yes jest.config.ts
check yes playwright.config.ts
check yes eslint.config.js
check yes webpack.config.js
check yes bun.lockb
check yes deno.json
check yes deny.toml
check yes Package@swift-5.9.swift
check yes Podfile.lock
check yes compose.yaml
check yes justfile

failed_tests=0
check_test() {
  local want=$1 path=$2 got=no
  if is_test_path "$path"; then got=yes; fi
  if [[ $got == "$want" ]]; then printf '  ok   test path %s %s\n' "$want" "$path"; else
    printf '  FAIL test path %s: want %s, got %s\n' "$path" "$want" "$got"
    failed_tests=$((failed_tests + 1))
  fi
}
echo "is_test_path"
check_test yes tests/test_rates.py
check_test yes tests/__init__.py
check_test yes tests/property/strategies.py
check_test yes src/domain/discount.test.ts
# Configuration inside a test directory configures the tests below it: not a test source.
check_test no tests/conftest.py
check_test no tests/pytest.ini
check_test no tests/.env
check_test no tests/property/pyproject.toml
check_test no tests/setup.cfg
check_test no src/__tests__/package.json
check_test yes Packages/Core/Tests/CoreTests/PasswordTests.swift
check_test no conftest.py
check_test no pyproject.toml
check_test no src/domain/vitest.setup.ts
check_test no Sources/App/Latest.swift
[[ $failed -eq 0 && $failed_tests -eq 0 ]]
