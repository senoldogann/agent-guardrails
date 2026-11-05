/**
 * Trusted Vitest configuration for mutation runs (human-owned; StrykerJS and the literal mutator use
 * it). Same as .agent/test-support/vitest.config.ts plus:
 * - a fixed fast-check seed, set before the integrity guard captures its baseline, so a mutant is
 *   killed or survives the same way every run;
 * - the kit invariant (.agent/runtime/invariant.ts|js) resolved to its no-op twin, whatever specifier
 *   imports it, so an invariant can never kill a mutant; only test assertions can.
 */
import path from "node:path";
import { defineConfig } from "vitest/config";

const invariantModule = path.resolve(".agent/runtime/invariant");
const invariantOff = path.resolve(".agent/mutation/invariant-off.ts");

export default defineConfig({
	plugins: [
		{
			name: "agent-invariant-off",
			enforce: "pre",
			async resolveId(source, importer, options) {
				const resolved = await this.resolve(source, importer, {
					...options,
					skipSelf: true,
				});
				const id = resolved?.id.replace(/\.(ts|js)$/, "");
				return id === invariantModule ? invariantOff : null;
			},
		},
	],
	test: {
		setupFiles: [
			".agent/mutation/fast-check-seed.ts",
			".agent/test-support/vitest-integrity.ts",
		],
		sequence: { hooks: "list" },
	},
});
