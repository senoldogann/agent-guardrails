/**
 * The project's Vitest configuration (human-owned; the Makefile passes it with --config).
 * The integrity guard must stay the first setup file, and hooks must run in declaration order
 * ("list") so the guard's afterEach runs before any hook a test file registers.
 * Add project options here; keep both settings below.
 */
import { defineConfig } from "vitest/config";

export default defineConfig({
	test: {
		setupFiles: [".agent/test-support/vitest-integrity.ts"],
		sequence: { hooks: "list" },
	},
});
