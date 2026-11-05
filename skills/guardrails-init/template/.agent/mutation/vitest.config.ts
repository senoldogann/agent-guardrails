/**
 * Trusted Vitest configuration for mutation runs (human-owned; StrykerJS and the literal mutator use
 * it). Same as .agent/test-support/vitest.config.ts plus a fixed fast-check seed, set before the
 * integrity guard captures its baseline, so a mutant is killed or survives the same way every run.
 */
import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		setupFiles: [
			".agent/mutation/fast-check-seed.ts",
			".agent/test-support/vitest-integrity.ts",
		],
		sequence: { hooks: "list" },
	},
});
