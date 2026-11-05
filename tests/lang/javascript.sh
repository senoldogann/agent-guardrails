#!/usr/bin/env bash
# Integration test: plain JavaScript template (Vitest + fast-check, JSDoc types) through the evidence pipeline.
# The adapters and integrity guard are shared with TypeScript (see typescript.sh for the tamper cases).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

new_project javascript
cd "$project"
printf '{ "name": "lang-js", "private": true, "type": "module" }\n' >package.json
pnpm add -D vitest fast-check >"$project/.setup.log" 2>&1 || {
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

finish javascript
