import ExhaustCore

/// Runs a property test that systematically explores the generator's output space, then reports a reduced counterexample on failure.
///
/// ```swift
/// let counterexample = #exhaust(personGen, .budget(.thorough)) { person in
///     person.age >= 0
/// }
/// ```
///
/// Or with a function reference:
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
/// The `Void` path detects `#expect` failures automatically (including inside helper functions) using `withExpectedIssue`. After reduction, the property is re-run one final time without suppression so `#expect` failures record with the reduced values. The only Exhaust artifact is the replay seed.
///
/// ## Settings
///
/// - `.budget(_)`: controls iteration budgets for coverage and sampling. Presets: `.quick` (100/100), `.standard` (200/200, default), `.thorough` (600/600), `.extensive` (2000/2000), or `.custom(coverage:sampling:)`. Scale any preset with arithmetic (`.thorough * 3`).
/// - `.replay(_)`: fixed seed for deterministic reproduction. Accepts a raw `UInt64` or a Crockford Base32 string. Skips structured coverage.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value instead.
/// - `.suppress(.logs)`: silences all console output. Overrides `.log(...)`.
/// - `.suppress(.all)`: skips issue reporting and silences all console output.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 200 test cases). Analyzes the generator to identify its independent parameters — numeric ranges, branch selections, and sequence lengths. If the generator is analyzable:
/// - For small parameter domains (each having 256 or fewer values): constructs a t-way covering array using a greedy density algorithm (Bryce and Colbourn 2009). Rows are generated lazily and tested immediately — the macro stops as soon as a failure is found. If the entire combinatorial space fits the budget, every combination is tested exhaustively.
/// - For large parameter domains: synthesizes problematic values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 200 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")

/// Reduces a value you already have instead of searching for one.
///
/// Provide a concrete value you suspect is a counterexample — recovered from a bug report, a saved regression, or a previous failure. Exhaust reflects it back through the generator to recover the choices that produce it, then reduces it to a minimal counterexample. The coverage and random-sampling phases do not run: this overload starts from `reflecting` and only reduces.
///
/// ```swift
/// let minimal = #exhaust(personGen, reflecting: personFromBugReport) { person in
///     person.age >= 0
/// }
/// ```
///
/// - Parameter reflecting: A concrete value to reduce. It must be reachable by `gen`; if the generator cannot reflect it, Exhaust reports an issue and returns the value unreduced.
/// - Returns: The reduced counterexample, or `nil` if the value does not fail the property.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustTestMacro")

/// Runs a property test with an async property closure, systematically exploring the generator's output space and reporting a reduced counterexample on failure.
///
/// Use this when the property needs to `await` — for example, calling actor-isolated methods or async APIs. The coverage, reduction, and PRNG core runs on a GCD thread; the async property closure is bridged via `Task` + semaphore.
///
/// ```swift
/// let counterexample = await #exhaust(transactionGen, .budget(.thorough)) { txn in
///     let result = try await ledger.process(txn)
///     #expect(result.balance >= 0)
/// }
/// ```
///
/// Or with a function reference:
/// ```swift
/// let counterexample = await #exhaust(transactionGen, property: validateTransaction)
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
/// await #exhaust(transactionGen) { txn in
///     await ledger.process(txn).balance >= 0
/// }
/// ```
///
/// **Swift Testing assertions** — uses `#expect` or `#require`:
/// ```swift
/// await #exhaust(transactionGen) { txn in
///     let result = try await ledger.process(txn)
///     #expect(result.balance >= 0)
///     #expect(result.currency == txn.currency)
/// }
/// ```
///
/// The `Void` path detects `#expect` failures automatically (including inside helper functions) using `withExpectedIssue`. After reduction, the property is re-run one final time without suppression so `#expect` failures record with the reduced values. The only Exhaust artifact is the replay seed.
///
/// ## Settings
///
/// - `.budget(_)`: controls iteration budgets for coverage and sampling. Presets: `.quick` (100/100), `.standard` (200/200, default), `.thorough` (600/600), `.extensive` (2000/2000), or `.custom(coverage:sampling:)`. Scale any preset with arithmetic (`.thorough * 3`).
/// - `.replay(_)`: fixed seed for deterministic reproduction. Accepts a raw `UInt64` or a Crockford Base32 string. Skips structured coverage.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value instead.
/// - `.suppress(.logs)`: silences all console output. Overrides `.log(...)`.
/// - `.suppress(.all)`: skips issue reporting and silences all console output.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 200 test cases). Analyzes the generator to identify its independent parameters — numeric ranges, branch selections, and sequence lengths. If the generator is analyzable:
/// - For small parameter domains (each having 256 or fewer values): constructs a t-way covering array using a greedy density algorithm (Bryce and Colbourn 2009). Rows are generated lazily and tested immediately — the macro stops as soon as a failure is found. If the entire combinatorial space fits the budget, every combination is tested exhaustively.
/// - For large parameter domains: synthesizes problematic values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 200 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")

/// Reduces a value you already have instead of searching for one, with an async property closure.
///
/// Use this when you have a concrete value to investigate and the property must `await`. Exhaust reflects the value back through the generator to recover the choices that produce it, then reduces it to a minimal counterexample. The coverage and random-sampling phases do not run: this overload starts from `reflecting` and only reduces.
///
/// ```swift
/// let minimal = await #exhaust(transactionGen, reflecting: txnFromBugReport) { txn in
///     try await ledger.process(txn).balance >= 0
/// }
/// ```
///
/// - Parameter reflecting: A concrete value to reduce. It must be reachable by `gen`; if the generator cannot reflect it, Exhaust reports an issue and returns the value unreduced.
/// - Returns: The reduced counterexample, or `nil` if the value does not fail the property.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")
