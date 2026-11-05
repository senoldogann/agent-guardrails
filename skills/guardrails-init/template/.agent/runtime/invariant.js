// @ts-check
/**
 * Kit invariant helper for plain JavaScript (human-owned); see invariant.ts next to it.
 * Import: import { invariant } from "<relative path>/.agent/runtime/invariant.js";
 * Call only as a statement: `invariant(<condition>, "Invariant: <what must hold>");`.
 * @param {boolean} condition
 * @param {string} message
 * @returns {asserts condition}
 */
export function invariant(condition, message) {
	if (!condition) {
		throw new Error(message);
	}
}
