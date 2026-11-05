/** Fixed fast-check seed for mutation runs (see vitest.config.ts here). */
import fc from "fast-check";

fc.configureGlobal({ ...fc.readConfigureGlobal(), seed: 20261105 });
