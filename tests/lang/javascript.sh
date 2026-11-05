#!/usr/bin/env bash
# Integration test: plain JavaScript template (Vitest + fast-check, JSDoc types) through the evidence pipeline.
# The adapters and integrity guard are shared with TypeScript (see typescript.sh for the tamper cases).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project javascript
cd "$project"
printf '{ "name": "lang-js", "private": true, "type": "module" }\n' >package.json
pnpm add -D vitest fast-check @stryker-mutator/core @stryker-mutator/vitest-runner >"$project/.setup.log" 2>&1 || {
  cat "$project/.setup.log"
  exit 1
}
mkdir -p src/domain

cat >src/domain/percent.prop.test.js <<'EOF'
import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { makePercent } from "./percent.js";

describe("makePercent", () => {
  it("AC-1: accepts [0, 100] and preserves the value", () => {
    fc.assert(
      fc.property(fc.double({ min: 0, max: 100, noNaN: true }), (n) => {
        expect(makePercent(n)).toEqual({ ok: true, value: n });
      }),
      { numRuns: 200 },
    );
  });
});
EOF

write_stub() {
  printf '%s\n' '// @ts-check' 'export const makePercent = (_input) => {' '  throw new Error("NotImplemented: makePercent");' '};' >src/domain/percent.js
}
write_correct() {
  printf '%s\n' '// @ts-check' '/** @param {number} input */' \
    'export const makePercent = (input) => (input >= 0 && input <= 100 ? { ok: true, value: input } : { ok: false, error: { kind: "range", input } });' \
    >src/domain/percent.js
}
write_wrong() {
  printf '%s\n' '// @ts-check' '/** @param {number} input */' 'export const makePercent = (input) => ({ ok: true, value: Math.round(input) });' >src/domain/percent.js
}

echo "javascript:"
write_stub
lock_tests src/domain/percent.prop.test.js <<'EOF'
src/domain/percent.prop.test.js::makePercent > AC-1: accepts [0, 100] and preserves the value
EOF
run_red_green write_stub write_correct write_wrong

# Mutation gate inputs: StrykerJS + the numeric-literal mutator over a scoped file.
write_correct
cat >src/domain/discount.js <<'EOF'
// @ts-check
/**
 * Rounded discount in minor units: round_half_up(subtotal * percent / 100).
 * @param {bigint} subtotal
 * @param {bigint} percent
 */
export const discountMinor = (subtotal, percent) => (subtotal * percent + 50n) / 100n;
EOF
write_discount_tests() {
  cat >src/domain/discount.test.js <<EOF
import { describe, expect, it } from "vitest";
import { discountMinor } from "./discount.js";

describe("discountMinor", () => {
  it("AC-1: rounds half up", () => {
    $1
  });
});
EOF
}
write_discount_tests 'for (const [subtotal, percent, expected] of [[1234n, 15n, 185n], [49n, 1n, 0n], [50n, 1n, 1n], [0n, 100n, 0n]]) {
      expect(discountMinor(subtotal, percent)).toBe(expected);
    }'
lock_file_tests M-1 src/domain/discount.test.js
run_mutation "strong suite" src/domain/discount.js
expect_all_killed "strong suite: zero non-killed mutants"
expect_mutant "strong suite: the literal mutator kills 50n -> 51n" killed "NumericLiteral: 50n -> 51n"

write_discount_tests 'expect(discountMinor(1234n, 15n)).toBe(185n);'
run_mutation "weak locked suite" src/domain/discount.js
expect_mutant "weak locked suite: 50n -> 51n survives" survived "NumericLiteral: 50n -> 51n"

finish javascript
