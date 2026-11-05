# Plain JavaScript spec patterns

Same layout, tools, test rules and integrity guard as `typescript.md`, with types in JSDoc checked by
`tsc -p jsconfig.json` (`checkJs`, `strict`). Guarantees are compile-time only where tsc runs;
callers outside the checked project get none, so constructors also validate at runtime.
The implementation-code rules (no `throw` except the stub's, no try/catch, no async code, no
module-level `let`/`var`), the kit invariant and the mutation gate of `typescript.md` apply unchanged;
import the invariant as `import { invariant } from "<relative path>/.agent/runtime/invariant.js";`.

## Contract (locked): `src/domain/percent.contract.js`

```js
// @ts-check
/** @typedef {number & { readonly __brand: "Percent" }} Percent */
/** @typedef {{ kind: "not-finite" | "negative" | "above-100", input: number }} PercentError */
/** @typedef {{ ok: true, value: Percent } | { ok: false, error: PercentError }} PercentResult */
/** @typedef {(input: number) => PercentResult} MakePercent */
export {};
```

## Implementation stub (write-allowed): `src/domain/percent.js`

The message must start with `NotImplemented:` (the spec gate checks it).

```js
// @ts-check
/** @type {import("./percent.contract.js").MakePercent} */
export const makePercent = (_input) => {
  throw new Error("NotImplemented: makePercent");
};
```

Banned: `@type {any}`, `{*}`, `@ts-ignore`, `@ts-expect-error` (enforced by `escape-check js`).
Property tests: `*.prop.test.js` with fast-check, titled `AC-<n>: <behaviour>`, run configuration
pinned in every `fc.assert`, no `it.each` in locked tests (examples in `typescript.md`).
Acceptance: one Vitest test per scenario in `*.acceptance.test.js`, titled `AC-<n>: <scenario>`.
