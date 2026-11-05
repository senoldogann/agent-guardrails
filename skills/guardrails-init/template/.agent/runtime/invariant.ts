/**
 * Kit invariant helper (human-owned). Implementation code imports it as the only module under `.agent/`:
 *   import { invariant } from "<relative path>/.agent/runtime/invariant.ts";
 * and calls it only as a statement: `invariant(<condition>, "Invariant: <what must hold>");`.
 * Use it for a condition that can never fail but lets the type checker narrow a value (for example to
 * a branded type) without a cast. Mutation runs swap it for a no-op (.agent/mutation/invariant-off.ts),
 * so a mutant can only be killed by a test assertion, never by the invariant itself.
 */
export function invariant(
	condition: boolean,
	message: string,
): asserts condition {
	if (!condition) {
		throw new Error(message);
	}
}
