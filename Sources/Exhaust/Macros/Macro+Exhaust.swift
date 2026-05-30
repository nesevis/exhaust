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
/// - For large parameter domains: synthesizes boundary values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 200 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue? = nil,
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
/// - For large parameter domains: synthesizes boundary values (domain edges, plus/minus 1 neighbors, midpoint, zero, and type-specific values like NaN and DST transitions) and constructs a covering array over those representatives.
/// - Each covering array row is replayed through the generator to produce a concrete test case. If the property fails on any row, the macro proceeds directly to test case reduction.
///
/// **2. Random sampling** (default: 200 iterations). Generates values using a seeded PRNG. Each value is tested against the property. Skipped entirely if structured coverage already tested every combination exhaustively.
///
/// **3. Test case reduction**. When a failing test case is found (in either phase), the macro reduces it to a simpler counterexample. The generator's choice tree is flattened to a linear choice sequence, then a series of simplification passes — structural deletion, value minimization, and reordering — are applied repeatedly until no pass can simplify further. The reduced counterexample is reported as a test failure with a replay seed for reproducibility.
@freestanding(expression)
@discardableResult
public macro exhaust<GeneratedValue, PropertyResult>(
    _ gen: ReflectiveGenerator<GeneratedValue>,
    reflecting: GeneratedValue? = nil,
    _ settings: PropertySettings...,
    property: @Sendable (GeneratedValue) async throws -> PropertyResult
) -> GeneratedValue? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncTestMacro")

/// Generates command sequences, executes them against a system under test, and verifies that all contracts hold after every step.
///
/// Define a spec with `@Contract`, marking the SUT with `@SystemUnderTest`, model state with `@Model`, transitions with `@Command`, and post-conditions with `@Invariant`. The macro generates sequences of commands, runs them against a fresh SUT instance, and checks invariants after each step. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func boundedQueueBehavior() {
///     #execute(BoundedQueueSpec.self, .commandLimit(20))
/// }
/// ```
///
/// ## Settings
///
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.onReport(_)`: registers a closure that receives an ``ExhaustReport`` with per-phase timing, invocation counts, and reduction statistics after the test completes.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: ContractSpec>(
    _ specType: Spec.Type,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustContractMacro")

/// Generates command sequences and executes them across concurrent lanes with deterministic interleaving at `await` boundaries.
///
/// Define a spec with `@Contract` and async `@Command` methods. The cooperative scheduler controls interleaving deterministically at command boundaries — the same seed produces the same lane assignment and command ordering. Commands that suspend multiple times internally consume additional schedule entries; once the schedule is exhausted, continuation-level lane assignment falls back to deterministic round-robin. Commands are distributed across two concurrent lanes by default. On failure, the command sequence and interleaving are reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueBehavior() async {
///     let result = await #execute(ConcurrentQueueSpec.self, .concurrent(3), .commandLimit(12))
/// }
/// ```
///
/// ## Settings
///
/// - `.concurrent(_)`: number of concurrent execution lanes (1 through 8, default 2). Higher values explore more complex interleavings but grow the search space combinatorially. Use `.concurrent(1)` as a sequential baseline to confirm that failures require concurrency.
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200).
/// - `.replay(_)`: fixed seed for deterministic reproduction. The same seed with the same concurrency level produces the same command ordering and lane assignment.
/// - `.idleTimeoutMs(_)`: maximum milliseconds the drain loop waits with no pending continuations before declaring a timeout (default 1000). When the idle timeout fires, the current command sequence is reported as a failure without reduction.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
/// - `.suppress(.all)`: skips issue reporting and silences all console output.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    _ settings: ConcurrentContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustConcurrentContractMacro")

/// Generates command sequences and dispatches them across real GCD threads to detect races in synchronous primitives.
///
/// Define a spec with `@ConcurrentContract`, using `@Oracle` instead of `@Model` for correctness checking (model updates inside command bodies would race with each other on real threads). Commands run on real OS threads with non-deterministic scheduling — the same seed does not guarantee the same interleaving. Bug detection relies on repetition across the sampling budget. Use this to catch races in locks, dispatch queues, and atomics that are invisible at `await` suspension points.
///
/// ```swift
/// @Test func counterThreadSafety() {
///     let result = #execute(CounterGCDSpec.self, .concurrent(2), .budget(.extensive))
/// }
/// ```
///
/// ## Settings
///
/// - `.concurrent(_)`: number of concurrent execution lanes (1 through 8, default 2). Each lane dispatches its commands to a separate GCD thread.
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200). Higher budgets increase the probability of hitting narrow race windows.
/// - `.replay(_)`: fixed seed for reproduction. Reproduces the same command sequence, but the interleaving depends on OS thread scheduling and may not fail on every run. Run the test repeatedly to reproduce.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
/// - `.suppress(.all)`: skips issue reporting and silences all console output.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: ConcurrentContractSpec>(
    _ specType: Spec.Type,
    _ settings: ConcurrentContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustGCDContractMacro")

/// Generates command sequences and dispatches them across real GCD threads, bridging async command execution via `Task` + semaphore.
///
/// Use this when the spec's `@Command` methods are `async` but the SUT uses synchronous primitives internally (locks, dispatch queues, atomics behind an async facade). Each lane gets a real OS thread; async commands are driven synchronously within that thread. Non-deterministic scheduling — bug detection relies on repetition across the sampling budget.
///
/// ```swift
/// @Test func asyncCounterThreadSafety() async {
///     let result = await #execute(AsyncCounterGCDSpec.self, .concurrent(2), .budget(.extensive))
/// }
/// ```
///
/// ## Settings
///
/// - `.concurrent(_)`: number of concurrent execution lanes (1 through 8, default 2). Each lane dispatches its commands to a separate GCD thread with async execution bridged via `Task` + semaphore.
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200). Higher budgets increase the probability of hitting narrow race windows.
/// - `.replay(_)`: fixed seed for reproduction. Reproduces the same command sequence, but the interleaving depends on OS thread scheduling and may not fail on every run. Run the test repeatedly to reproduce.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
/// - `.suppress(.all)`: skips issue reporting and silences all console output.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncConcurrentContractSpec>(
    _ specType: Spec.Type,
    _ settings: ConcurrentContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncGCDContractMacro")
