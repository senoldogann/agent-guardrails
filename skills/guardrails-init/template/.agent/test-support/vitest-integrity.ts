/**
 * Locked test-integrity guard; the first setup file of every Vitest run (see vitest.config.ts here).
 *
 * Implementation code runs inside the test process, so it can neuter tests: override matchers with
 * `expect.extend`, patch chai, lower fast-check's global run count, or blind this guard by patching
 * the built-ins it compares with (`Object.is = () => true`). This file captures, when a test file
 * starts (before the file imports implementation code):
 * - the built-in functions it uses itself, so later patches cannot change its own behaviour;
 * - references to every own property of the assertion machinery, fast-check's global config and the
 *   built-ins `Object`, `Object.prototype`, `Reflect`, `Function.prototype`, `Array`,
 *   `Array.prototype`, `Map`, `Map.prototype` and `JSON`, plus the global bindings of the built-ins
 *   (all of `globalThis` would be noisy: Node defines some globals lazily).
 * It fails every test, and the file itself, once any reference was replaced, added or removed.
 * The guard avoids array methods, iterators, Map and template literals at check time, since those are
 * what a patch would target. It raises the bar; mutation testing remains the backstop.
 */
import fc from "fast-check";
import { afterAll, afterEach, beforeEach, chai, expect } from "vitest";

// Built-ins used at check time, captured before any implementation code runs.
const objectIs = Object.is;
const hasOwn = Object.hasOwn;
const createObject = Object.create;
const ownKeys = Reflect.ownKeys;
const getDescriptor = Reflect.getOwnPropertyDescriptor;
const reflectGet = Reflect.get;
const toText = String;
const GuardError = Error;
const readFastCheckConfig = fc.readConfigureGlobal;

/** Property name -> referenced value; a null-prototype object, so no inherited accessor is involved. */
type Table = Record<string, unknown>;

const JEST_MATCHERS = Symbol.for("$$jest-matchers-object");

const GLOBAL_BUILTINS: readonly string[] = [
	"Object",
	"Reflect",
	"Function",
	"Array",
	"Map",
	"Set",
	"WeakMap",
	"JSON",
	"Math",
	"Promise",
	"Symbol",
	"String",
	"Number",
	"Boolean",
	"Error",
	"TypeError",
	"Proxy",
	"eval",
	"globalThis",
];

const newTable = (): Table => {
	const table: Table = createObject(null);
	return table;
};

const descriptorPart = (
	descriptor: PropertyDescriptor | undefined,
	part: "value" | "get" | "set",
): unknown =>
	descriptor !== undefined && hasOwn(descriptor, part)
		? descriptor[part]
		: undefined;

const recordProperties = (
	table: Table,
	label: string,
	target: object,
): void => {
	const keys = ownKeys(target);
	for (let index = 0; index < keys.length; index += 1) {
		const key = keys[index];
		if (key === undefined) continue;
		const descriptor = getDescriptor(target, key);
		const name = label + "." + toText(key);
		table[name + ":value"] = descriptorPart(descriptor, "value");
		table[name + ":get"] = descriptorPart(descriptor, "get");
		table[name + ":set"] = descriptorPart(descriptor, "set");
	}
};

const recordNamedProperties = (
	table: Table,
	label: string,
	target: object,
	names: readonly string[],
): void => {
	for (let index = 0; index < names.length; index += 1) {
		const name = names[index];
		if (name === undefined) continue;
		const descriptor = getDescriptor(target, name);
		const entry = label + "." + name;
		table[entry + ":value"] = descriptorPart(descriptor, "value");
		table[entry + ":get"] = descriptorPart(descriptor, "get");
		table[entry + ":set"] = descriptorPart(descriptor, "set");
	}
};

const objectProperty = (
	owner: object,
	key: PropertyKey,
	what: string,
): object => {
	const value: unknown = reflectGet(owner, key);
	if (typeof value !== "object" || value === null) {
		throw new GuardError(
			what + " is missing; update .agent/test-support/vitest-integrity.ts",
		);
	}
	return value;
};

const takeSnapshot = (): Table => {
	const table = newTable();
	const jestState = objectProperty(
		globalThis,
		JEST_MATCHERS,
		"Vitest's global matchers object",
	);
	recordProperties(table, "chai.Assertion.prototype", chai.Assertion.prototype);
	recordProperties(table, "chai.Assertion", chai.Assertion);
	recordProperties(table, "expect", expect);
	recordProperties(
		table,
		"jestMatchers",
		objectProperty(jestState, "matchers", "Vitest's matchers table"),
	);
	recordNamedProperties(table, "globalThis", globalThis, GLOBAL_BUILTINS);
	recordProperties(table, "Object", Object);
	recordProperties(table, "Object.prototype", Object.prototype);
	recordProperties(table, "Reflect", Reflect);
	recordProperties(table, "Function.prototype", Function.prototype);
	recordProperties(table, "Array", Array);
	recordProperties(table, "Array.prototype", Array.prototype);
	recordProperties(table, "Map", Map);
	recordProperties(table, "Map.prototype", Map.prototype);
	recordProperties(table, "JSON", JSON);
	table["fastCheck.globalConfig"] = readFastCheckConfig();
	return table;
};

/** Comma-separated names whose reference changed, appeared or disappeared ("" when unchanged). */
const changedNames = (before: Table, after: Table): string => {
	let changed = "";
	const beforeKeys = ownKeys(before);
	for (let index = 0; index < beforeKeys.length; index += 1) {
		const key = beforeKeys[index];
		if (typeof key !== "string") continue;
		if (!hasOwn(after, key) || !objectIs(after[key], before[key])) {
			changed = changed + (changed === "" ? "" : ", ") + key;
		}
	}
	const afterKeys = ownKeys(after);
	for (let index = 0; index < afterKeys.length; index += 1) {
		const key = afterKeys[index];
		if (typeof key === "string" && !hasOwn(before, key)) {
			changed = changed + (changed === "" ? "" : ", ") + key;
		}
	}
	return changed;
};

const assertUnchanged = (baseline: Table, when: string): void => {
	const changed = changedNames(baseline, takeSnapshot());
	if (changed !== "") {
		throw new GuardError(
			"Test integrity violated (" +
				when +
				"): " +
				changed +
				" changed after the test file started. " +
				"Implementation code must not modify built-ins or test, assertion or property-runner machinery.",
		);
	}
};

// Trusted run configuration, set before the baseline: fast-check failure messages carry the thrown
// error, so the results show the root cause (verify-red looks for the stub's NotImplemented).
fc.configureGlobal({ ...fc.readConfigureGlobal(), includeErrorInReport: true });

const baseline = takeSnapshot();

beforeEach(() => {
	assertUnchanged(baseline, "before test");
});

afterEach(() => {
	assertUnchanged(baseline, "after test");
});

afterAll(() => {
	assertUnchanged(baseline, "after all tests of the file");
});
