#!/usr/bin/env bash
# Integration test: TypeScript template (Vitest + fast-check) through the evidence pipeline.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project typescript
cd "$project"
printf '{ "name": "lang-ts", "private": true, "type": "module" }\n' >package.json
pnpm add -D vitest fast-check @biomejs/biome @stryker-mutator/core @stryker-mutator/vitest-runner >"$project/.setup.log" 2>&1 || {
  cat "$project/.setup.log"
  exit 1
}
mkdir -p src/domain

cat >src/domain/percent.prop.test.ts <<'EOF'
import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { makePercent } from "./percent.ts";

const runs = { numRuns: 200, endOnFailure: false } as const;

describe("makePercent", () => {
  it("AC-1: accepts [0, 100] and preserves the value", () => {
    fc.assert(
      fc.property(fc.double({ min: 0, max: 100, noNaN: true }), (n) => {
        expect(makePercent(n)).toEqual({ ok: true, value: n });
      }),
      runs,
    );
  });
  it("AC-2: rejects negatives", () => {
    fc.assert(
      fc.property(fc.double({ min: -Number.MAX_VALUE, max: -Number.MIN_VALUE, noNaN: true }), (n) => {
        expect(makePercent(n)).toEqual({ ok: false, error: { kind: "negative", input: n } });
      }),
      runs,
    );
  });
});
EOF

write_other_test() {
  cat >src/other.test.ts <<EOF
import { expect, it } from "vitest";
it$1("unit: arithmetic still works", () => {
  expect(1 + 1).toBe(2);
});
EOF
}
write_other_test ""

write_stub() {
  cat >src/domain/percent.ts <<'EOF'
export const makePercent = (_input: number): unknown => {
  throw new Error("NotImplemented: makePercent");
};
EOF
}
write_correct() {
  cat >src/domain/percent.ts <<'EOF'
export const makePercent = (input: number): unknown => {
  if (Number.isNaN(input) || !Number.isFinite(input)) return { ok: false, error: { kind: "not-finite", input } };
  if (input < 0) return { ok: false, error: { kind: "negative", input } };
  if (input > 100) return { ok: false, error: { kind: "above-100", input } };
  return { ok: true, value: input };
};
EOF
}
write_wrong() {
  cat >src/domain/percent.ts <<'EOF'
export const makePercent = (input: number): unknown =>
  input < 0 ? { ok: false, error: { kind: "negative", input } } : { ok: true, value: Math.round(input) };
EOF
}
write_matcher_override() {
  cat >src/domain/percent.ts <<'EOF'
import { expect } from "vitest";
expect.extend({ toEqual: () => ({ pass: true, message: () => "" }) });
export const makePercent = (_input: number): unknown => ({ ok: true, value: 0 });
EOF
}
write_fast_check_override() {
  cat >src/domain/percent.ts <<'EOF'
import fc from "fast-check";
fc.configureGlobal({ numRuns: 1, examples: [[50]] });
export const makePercent = (input: number): unknown => (input === 50 ? { ok: true, value: 50 } : { ok: true, value: 0 });
EOF
}

write_blinding_attack() {
  cat >src/domain/percent.ts <<'EOF2'
import { expect } from "vitest";
const global = (() => undefined).constructor("return this")();
global.Object.is = () => true;
expect.extend({ toEqual: () => ({ pass: true, message: () => "" }) });
export const makePercent = (_input: number): unknown => ({ ok: true, value: 0 });
EOF2
}
restriction_lint() {
  pnpm exec biome lint --error-on-warnings --config-path .agent/lint/biome-restrictions.json .
}

echo "typescript:"
write_stub
lock_tests src/domain/percent.prop.test.ts <<'EOF'
src/domain/percent.prop.test.ts::makePercent > AC-1: accepts [0, 100] and preserves the value
src/domain/percent.prop.test.ts::makePercent > AC-2: rejects negatives
EOF
run_red_green write_stub write_correct write_wrong
write_stub
(cd "$project" && make --no-print-directory test >/dev/null 2>&1) || true
expect_result "stub: fast-check failure reports the NotImplemented cause" \
  "src/domain/percent.prop.test.ts::makePercent > AC-1: accepts [0, 100] and preserves the value" failed "NotImplemented: makePercent"

write_correct
write_other_test ".skip"
expect_success "skip: make test passes (exit code alone would accept it)" make --no-print-directory test
expect_failure "skip: verify-green fails on a skipped test" .agent/bin/verify-green "$ticket"
expect_output "skip: verify-green names the skipped test" "src/other.test.ts::unit: arithmetic still works"
write_other_test ""

write_matcher_override
expect_failure "expect.extend override: make test fails" make --no-print-directory test
expect_failure "expect.extend override: verify-green fails" .agent/bin/verify-green "$ticket"
expect_result "expect.extend override: integrity guard reports it" \
  "src/domain/percent.prop.test.ts::makePercent > AC-1: accepts [0, 100] and preserves the value" failed "Test integrity violated"

write_fast_check_override
expect_failure "fc.configureGlobal override: verify-green fails" sh -c 'make --no-print-directory test; .agent/bin/verify-green T-1'
expect_result "fc.configureGlobal override: integrity guard reports it" \
  "src/domain/percent.prop.test.ts::makePercent > AC-1: accepts [0, 100] and preserves the value" failed "fastCheck.globalConfig"

write_blinding_attack
expect_failure "Object.is blinding + matcher override: verify-green fails" sh -c 'make --no-print-directory test; .agent/bin/verify-green T-1'
expect_result "Object.is blinding + matcher override: integrity guard reports the patched built-in" \
  "src/domain/percent.prop.test.ts::makePercent > AC-1: accepts [0, 100] and preserves the value" failed "Object.is:value"
expect_failure "Object.is blinding: restriction lint rejects the implementation" restriction_lint
expect_output "Object.is blinding: lint names the .constructor access" "reaches the Function constructor"

write_correct
expect_success "correct: restriction lint passes" restriction_lint
write_stub
expect_success "stub: restriction lint allows throw new Error(\"NotImplemented: ...\")" restriction_lint
cat >src/domain/percent.ts <<'EOF'
export const makePercent = (input: number): unknown => {
	if (input > 1000) throw new RangeError("invariant violated");
	return { ok: true, value: input };
};
EOF
expect_failure "self-check throw: restriction lint rejects it" restriction_lint
expect_output "self-check throw: lint names the throw rule" "is banned in implementation code (contracts return typed results)"
cat >src/domain/percent.ts <<'EOF'
export const makePercent = (input: number): unknown => {
	if (input > 1000) throw new Error("Invariant: input was validated by the caller");
	return { ok: true, value: input };
};
EOF
expect_success "invariant throw: restriction lint allows throw new Error(\"Invariant: ...\")" restriction_lint
printf '// Stryker disable next-line all: equivalent\nexport const one = 1;\n' >src/domain/suppressed.ts
git add src/domain/suppressed.ts
expect_failure "Stryker suppression comment: escape-check rejects it" .agent/bin/escape-check ts
git rm -q -f src/domain/suppressed.ts
write_correct

# Mutation gate inputs: StrykerJS + the numeric-literal mutator over a scoped file.
cat >src/domain/discount.ts <<'EOF'
/** Rounded discount in minor units: round_half_up(subtotal * percent / 100). */
export const discountMinor = (subtotal: bigint, percent: bigint): bigint =>
	(subtotal * percent + 50n) / 100n;
EOF
write_discount_tests() {
  cat >"src/domain/$1" <<EOF
import { describe, expect, it } from "vitest";
import { discountMinor } from "./discount.ts";

describe("discountMinor", () => {
	it("$2", () => {
		const table: ReadonlyArray<readonly [bigint, bigint, bigint]> = [
			[1234n, 15n, 185n],
			[49n, 1n, 0n],
			[50n, 1n, 1n],
			[0n, 100n, 0n],
		];
		for (const [subtotal, percent, expected] of table) {
			expect(discountMinor(subtotal, percent)).toBe(expected);
		}
	});
});
EOF
}
write_discount_tests discount.test.ts "AC-1: rounds half up at the boundaries"
lock_file_tests M-1 src/domain/discount.test.ts
run_mutation "strong suite" src/domain/discount.ts
expect_all_killed "strong suite: zero non-killed mutants"
expect_mutant "strong suite: the literal mutator kills 50n -> 51n" killed "NumericLiteral: 50n -> 51n"
expect_mutant "strong suite: Stryker mutants are in the results" killed "ArithmeticOperator"

cat >src/domain/discount.test.ts <<'EOF'
import { describe, expect, it } from "vitest";
import { discountMinor } from "./discount.ts";

describe("discountMinor", () => {
	it("AC-1: returns a bigint", () => {
		expect(typeof discountMinor(1234n, 15n)).toBe("bigint");
	});
});
EOF
write_discount_tests discount-extra.test.ts "unit: rounds half up (not locked)"
lock_file_tests M-1 src/domain/discount.test.ts
run_mutation "weak locked suite" src/domain/discount.ts
expect_mutant "weak locked suite: a kill by unlocked tests only counts as survived" survived "(killed only by unlocked tests)"
expect_mutant "weak locked suite: 50n -> 51n survives" survived "NumericLiteral: 50n -> 51n"
rm src/domain/discount-extra.test.ts

finish typescript
