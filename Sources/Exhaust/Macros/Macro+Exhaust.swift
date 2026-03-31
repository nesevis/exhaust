import ExhaustCore

/// Runs a property test that systematically explores the generator's output space, then reports a reduced counterexample on failure.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 200 test cases). Analyzes the generator to identify its independent parameters — numeric ranges, branch selections, and sequence lengths. If the generator is analyzable:
/// - For small parameter domains (each having 256 or fewer values): constructs a t-way covering array using a greedy density algorithm (Bryce and Colbourn 2009). Rows are generated lazily and tested immediately — the macro stops as soon as a failure is found. If the entire combinatorial space fits the budget, every combination is tested exhaustively.
/// - For large parameter domains: synthesizes boundary values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 200 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
///
/// ## Settings
///
/// - `.budget(_)`: controls iteration budgets for coverage, sampling, and reduction. Presets: `.expedient` (200/200, default), `.expensive` (500/500), `.exorbitant` (2000/2000), or `.custom(coverage:sampling:reduction:)`.
/// - `.replay(_)`: fixed seed for deterministic reproduction. Accepts a raw `UInt64` or a Crockford Base32 string. Skips structured coverage.
/// - `.reflecting(_)`: skips generation, reflects an existing value through the generator, and reduces it.
/// - `.randomOnly`: disables structured coverage analysis.
/// - `.suppressIssueReporting`: skips `reportIssue()` — useful when the caller asserts on the returned value instead.
///
/// ## Examples
///
/// Trailing closure (source code captured):
/// ```swift
/// let counterexample = #exhaust(personGen, .budget(.expensive)) { person in
///     person.age >= 0
/// }
/// ```
///
/// Function reference (no source capture):
/// ```swift
/// let counterexample = #exhaust(personGen, .replay("8DZR69"), property: isValid)
/// ```
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all test cases pass.
///
/// ## Property Signatures
///
/// The property closure can return `Bool` or `Void`:
///
/// **Boolean predicate** — returns `true` for passing values:
/// ```swift
/// #exhaust(personGen) { person in person.age >= 0 }
/// ```
///
/// **Swift Testing assertions** — uses `#expect` or `#require`:
/// ```swift
/// #exhaust(personGen) { person in
///     #expect(person.age >= 0)
///     #expect(person.name.isEmpty == false)
/// }
/// ```
///
/// The `Void` path detects `#expect` failures automatically (including inside helper functions) using `withKnownIssue`. After reduction, the property is re-run one final time without suppression so `#expect` failures record with the reduced values. The only Exhaust artifact is the replay seed.
@freestanding(expression)
@discardableResult
public macro exhaust<T, R>(
    _ gen: ReflectiveGenerator<T>,
    _ settings: ExhaustSettings<T>...,
    property: (T) throws -> R
) -> T? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")

/// Runs a property test with an async property closure.
///
/// Identical to the synchronous `#exhaust` overload but for properties that require `await` — for example, properties that call actor-isolated methods. Must be called with `await` since the expanded function is `async`. The synchronous core (coverage, reduction, PRNG) runs on a GCD thread; the async property closure is bridged via `Task` + semaphore.
///
/// - Returns: The reduced counterexample if the property fails, or `nil` if all test cases pass.
@freestanding(expression)
@discardableResult
public macro exhaust<T, R>(
    _ gen: ReflectiveGenerator<T>,
    _ settings: ExhaustSettings<T>...,
    property: (T) async throws -> R
) -> T? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")

/// Runs a contract property test that generates command sequences, executes them against the system under test, and verifies that contracts (invariants, postconditions, and optional model comparisons) hold after every step.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 2000 test cases). Builds a covering array over the command-type domain — each parameter is a position in the command sequence, each domain value is a command type. Rows are generated lazily using a greedy density algorithm and tested immediately, stopping as soon as a failure is found.
///
/// **2. Random sampling** (default: 100 iterations). Generates random command sequences with weighted command selection.
///
/// **3. Test case reduction**. When a failing sequence is found, the existing Reducer strategies apply — deleting commands, simplifying arguments, reordering steps — until a minimal counterexample is found.
///
/// ## Parameters
///
/// - `commandLimit`: The maximum number of commands per generated sequence. The reducer can shrink below this value.
///
/// ## Settings
///
/// - `.samplingBudget(_)`: upper bound on random sampling iterations (default 100).
/// - `.coverageBudget(_)`: maximum test cases for structured coverage (default 200).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.reductionBudget(_)`: controls reduction aggressiveness.
/// - `.randomOnly`: disables structured coverage analysis.
/// - `.argumentAwareCoverage`: includes command argument values in SCA domain construction.
///
/// ## Example
///
/// ```swift
/// @Test func boundedQueueBehavior() {
///     #exhaust(BoundedQueueSpec.self, commandLimit: 20)
/// }
/// ```
///
/// - Returns: A ``ContractResult`` containing the shrunk command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro exhaust<Spec: ContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustContractMacro")

/// Runs an async contract property test that generates command sequences, executes them against an async system under test, and verifies that contracts hold after every step.
///
/// Identical to the synchronous `#exhaust(Spec.self, commandLimit:)` overload but for types conforming to ``AsyncContractSpec``. Must be called with `await` since the expanded function is `async`. The synchronous core (coverage, reduction, PRNG) runs on a GCD thread; async `run`/`checkInvariants` calls are bridged via `Task` + semaphore.
///
/// - Returns: A ``ContractResult`` containing the shrunk command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro exhaust<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    commandLimit: Int,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncContractMacro")
