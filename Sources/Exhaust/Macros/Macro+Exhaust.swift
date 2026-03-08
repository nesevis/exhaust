import ExhaustCore

/// Runs a property test that systematically explores the generator's output space, then reports a reduced counterexample on failure.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 2000 test cases). Analyzes the generator to identify its independent parameters — numeric ranges, branch selections, and sequence lengths. If the generator is analyzable:
/// - For small parameter domains (each having 256 or fewer values): constructs a t-way covering array using the IPOG algorithm. Strength is chosen adaptively — the strongest covering that fits the budget. If the entire combinatorial space fits, every combination is tested exhaustively.
/// - For large parameter domains: synthesizes boundary values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 100 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
///
/// ## Settings
///
/// - `.maxIterations(_)`: upper bound on random sampling iterations (default 100). Additive with the coverage budget.
/// - `.coverageBudget(_)`: maximum test cases for structured coverage (default 2000).
/// - `.replay(_)`: fixed seed for deterministic reproduction. Skips structured coverage.
/// - `.reductionBudget(_)`: controls test case reduction aggressiveness (`.fast` or `.slow`).
/// - `.reflecting(_)`: skips generation, reflects an existing value through the generator, and reduces it.
/// - `.randomOnly`: disables structured coverage analysis.
/// - `.suppressIssueReporting`: skips `reportIssue()` — useful when the caller asserts on the returned value instead.
///
/// ## Examples
///
/// Trailing closure (source code captured):
/// ```swift
/// let counterexample = #exhaust(personGen, .maxIterations(1000)) { person in
///     person.age >= 0
/// }
/// ```
///
/// Function reference (no source capture):
/// ```swift
/// let counterexample = #exhaust(personGen, .replay(42), property: isValid)
/// ```
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all test cases pass.
@freestanding(expression)
@discardableResult
public macro exhaust<T>(
    _ gen: ReflectiveGenerator<T>,
    _ settings: ExhaustSettings<T>...,
    property: (T) throws -> Bool,
) -> T? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")
