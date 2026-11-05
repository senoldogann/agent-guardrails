/**
 * StrykerJS ignorer (human-owned): no mutants inside `invariant(...)` statements whose `invariant` is
 * imported from the kit module .agent/runtime/invariant. Their condition can never fail and the
 * mutation run makes the helper a no-op, so such mutants could only survive as equivalents.
 * .agent/bin/mutants-stryker does not count mutants carrying exactly this reason.
 */
export const INVARIANT_REASON =
	"agent-invariant: owner-approved invariant, not mutated";

const isKitInvariant = (path) => {
	if (!path.isIdentifier({ name: "invariant" })) return false;
	const binding = path.scope.getBinding("invariant");
	const declaration = binding?.path.parentPath;
	return (
		binding?.kind === "module" &&
		declaration?.isImportDeclaration() === true &&
		/(^|\/)\.agent\/runtime\/invariant\.(ts|js)$/.test(
			declaration.node.source.value,
		)
	);
};

export const strykerPlugins = [
	{
		kind: "Ignore",
		name: "agent-invariant",
		value: {
			shouldIgnore(path) {
				const call = path.isExpressionStatement()
					? path.get("expression")
					: path;
				return call.isCallExpression() && isKitInvariant(call.get("callee"))
					? INVARIANT_REASON
					: undefined;
			},
		},
	},
];
