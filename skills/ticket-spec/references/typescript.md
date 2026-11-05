# TypeScript spec patterns

Tools: TypeScript strict, Biome (+ `.agent/lint/no-type-assertion.grit`), Vitest, fast-check.
Vitest runs with `.agent/test-support/vitest.config.ts` (the Makefile passes it). That config
loads the integrity guard, which fails every test once implementation code patches matchers or
fast-check's global config. Implementation code under `src/` also passes the restriction lint
(`.agent/lint/biome-restrictions.json`): it may not import test frameworks, exit the process,
use `globalThis`/`process`, access `.constructor`/`__proto__`, or modify built-ins and prototypes. `src/domain/**` may not import Node built-ins at all.
It may not `throw` either, except the stub's `throw new Error("NotImplemented: ...")`: contracts return
typed results, and a throwing self-check would kill mutants without any locked test noticing. It may
also not use `try`/`catch`/`finally`, async code (`async`, `await`, `Promise`, `.then`/`.catch`/`.finally`),
module-level `let`/`var`, or import anything from `.agent/` except the kit invariant (see Invariants).

Mutation gate (`make test-mutation`): StrykerJS plus a numeric-literal mutator (n+1, n-1) run against
the changed source files; a mutant counts as killed only when a locked test fails. Every boundary
constant therefore needs a deterministic example on each side of it (e.g. a rounding table with
`x.49` and `x.50` cases), not only random property inputs.

## Contract (locked): `src/domain/percent.contract.ts`

Validation errors are values, not exceptions: TypeScript cannot type `throw`.

```ts
declare const percentBrand: unique symbol;
/** A percentage in [0, 100]. Only `makePercent` produces one. */
export type Percent = number & { readonly [percentBrand]: true };

/** Money in minor units (cents), never fractional. */
export type Money = { readonly minorUnits: bigint; readonly currency: string };

export type PercentError =
  | { readonly kind: "not-finite"; readonly input: number }
  | { readonly kind: "negative"; readonly input: number }
  | { readonly kind: "above-100"; readonly input: number };

export type Result<T, E> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly error: E };

export type MakePercent = (input: number) => Result<Percent, PercentError>;
export type ApplyDiscount = (price: Money, discount: Percent) => Money;
```

## Implementation stub (write-allowed): `src/domain/percent.ts`

Every stub throws an error whose message starts with `NotImplemented:`. The spec gate
(`verify-red`) requires every locked test to fail with that message, which proves the test reaches
the implementation instead of failing on an import or an assertion typo.

```ts
import type { MakePercent } from "./percent.contract.ts";

export const makePercent: MakePercent = (_input) => {
  throw new Error("NotImplemented: makePercent");
};
```

The implementer brands without a cast through a type guard: `const isPercent = (n: number): n is Percent => …`.
A lying guard is caught by the property tests.

## Property test (locked): `src/domain/percent.prop.test.ts`

- Name every test `AC-<n>: <behaviour>`, one criterion per test; the ID is
  `<file>::<describe> > <title>`, and trace-check reads the `AC-<n>` from it.
- Pin the run configuration in every `fc.assert` (`numRuns` at least); do not rely on defaults.
- No `it.each`/`test.each` in locked tests: each case must have its own stable title.
- Generators must match the criterion exactly. `fc.double({ max: -Number.MIN_VALUE })` also yields
  `-Infinity`, which is "not-finite", not "negative"; bound both ends.

```ts
import fc from "fast-check";
import { describe, expect, it } from "vitest";
import { makePercent } from "./percent.ts";

const runs = { numRuns: 200 } as const;

describe("makePercent", () => {
  it("AC-1: accepts exactly [0, 100] and preserves the value", () => {
    fc.assert(
      fc.property(fc.double({ min: 0, max: 100, noNaN: true }), (n) => {
        expect(makePercent(n)).toEqual({ ok: true, value: n });
      }),
      runs,
    );
  });
  it("AC-2: rejects finite negatives", () => {
    fc.assert(
      fc.property(fc.double({ min: -Number.MAX_VALUE, max: -Number.MIN_VALUE, noNaN: true }), (n) => {
        expect(makePercent(n)).toEqual({ ok: false, error: { kind: "negative", input: n } });
      }),
      runs,
    );
  });
  it("AC-3: rejects NaN and infinities as not-finite", () => {
    fc.assert(
      fc.property(fc.constantFrom(Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY), (n) => {
        expect(makePercent(n)).toEqual({ ok: false, error: { kind: "not-finite", input: n } });
      }),
      runs,
    );
  });
});
```

Edge values belong to the criterion they test: `0`, `-0`, `100` in AC-1; `100.0000001` in the
above-100 criterion; `-Number.MIN_VALUE` in AC-2.

## Acceptance

One Vitest test per acceptance scenario in `src/**/*.acceptance.test.ts` (locked), titled
`AC-<n>: <scenario>`, with Given/When/Then as comments. A `specs/<ID>/*.feature` file is optional
documentation; the kit ships no Gherkin runner.

## Invariants

When a value must be narrowed (for example to a branded type) by a condition that can never fail,
use the kit helper, the only `.agent/` module implementation code may import. Import it exactly as
`import { invariant } from "<relative path>/.agent/runtime/invariant.ts";` and call it only as a
statement whose message is a string literal starting with `Invariant: `:

```ts
import { invariant } from "../../.agent/runtime/invariant.ts";

const provenNonNegative = (n: bigint): NonNegativeMinor => {
	invariant(isNonNegativeMinor(n), "Invariant: applyDiscount amounts are non-negative");
	return n;
};
```

`invariant` is an assertion function (`asserts condition`), so the type checker narrows `n` without a
cast. Mutation runs resolve it to a no-op, so a mutant is killed only when a locked test assertion
fails, and the mutants inside the `invariant(...)` statement are not generated or counted. The
condition must not hide logic: anything the tests must check lives outside the statement.
