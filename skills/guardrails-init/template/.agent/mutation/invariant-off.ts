/**
 * No-op twin of .agent/runtime/invariant.ts for mutation runs (human-owned). The trusted mutation
 * Vitest config resolves every import of the kit invariant to this module, so an invariant never
 * throws and a mutant counts as killed only when a test assertion fails.
 */
export function invariant(
	_condition: boolean,
	_message: string,
): asserts _condition {}
