// Macro declarations for running spec tests with `#execute`.
//
// `#execute(MySpec.self, .settings...)` runs a spec test at the call site, dispatching to the runner selected by the spec's `ExecutionModel`. The `@StateMachine` declaration macro and its markers live in `Macro+StateMachine.swift`.
import ExhaustCore

/// Runs a synchronous spec test, dispatching to the `.sequential`, `.tasks`, or `.threads` runner based on the spec's ``ExecutionModel``.
///
/// `.sequential` and `.tasks` specs run commands one at a time and check `@Invariant` after each step. A synchronous `.tasks` spec has no suspension points to interleave at, so it executes sequentially. Cooperative interleaving requires async commands (``AsyncStateMachineSpec``). `.threads` dispatches commands across real GCD threads and checks the `@Oracle` against a sequential replay. On failure, the sequence is reduced to a minimal counterexample. Always awaited: the test function must be `async` even when every command is synchronous.
///
/// ```swift
/// @Test func boundedQueueBehavior() async {
///     await #execute(BoundedQueueSpec.self, .commandLimit(20))
/// }
/// ```
///
/// Settings are variadic ``StateMachineSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is <doc:StateMachineTesting>.
///
/// - Returns: A ``StateMachineResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustStateMachineMacro")

/// Runs a coverage-guided spec test that mutates command sequences from a corpus toward novel SUT coverage until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `.threads` specs are not supported: the search treats an attempt's coverage as determined by its command sequence, and preemptive scheduling makes it depend on an OS schedule the run can neither observe nor replay, so coverage novelty would reward scheduling luck instead of new behavior. Run `.threads` specs under plain `#execute`, whose oracle checking relies on repetition rather than coverage.
///
/// ```swift
/// @Test func boundedQueueFuzz() async {
///     await #execute(BoundedQueueSpec.self, time: .minutes(5))
/// }
/// ```
///
/// Settings are variadic ``FuzzSettings`` values controlling deterministic replay, output suppression, log verbosity, and the per-sequence command limit (``FuzzSettings/commandLimit(_:)``).
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Note: A spec's `failureDescription()` is not surfaced in `time:` mode; the reported counterexample is the reduced command sequence.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro execute<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    time: TimeSpan,
    _ settings: FuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExecuteTimeMacro")

/// Runs a coverage-guided spec test for an async spec that mutates command sequences from a corpus toward novel SUT coverage until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `.sequential` specs run commands one at a time, awaiting each command and invariant check. `.tasks` specs drain each sequence through the cooperative scheduler: every command carries a lane-assigning schedule marker drawn as part of the generated input, so the interleaving itself is searched, mutated, and reduced alongside the commands (``FuzzSettings/parallelize(lanes:)`` sets the lane count, defaulting to two). `.tasks` requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2. `.threads` specs are not supported: the search treats an attempt's coverage as determined by its command sequence, and preemptive scheduling makes it depend on an OS schedule the run can neither observe nor replay, so coverage novelty would reward scheduling luck instead of new behavior. Run `.threads` specs under plain `#execute`, whose oracle checking relies on repetition rather than coverage.
///
/// ```swift
/// @Test func concurrentQueueFuzz() async {
///     await #execute(ConcurrentQueueSpec.self, time: .minutes(5), .parallelize(lanes: .two))
/// }
/// ```
///
/// Settings are variadic ``FuzzSettings`` values controlling deterministic replay, output suppression, log verbosity, the per-sequence command limit (``FuzzSettings/commandLimit(_:)``), and the lane count (``FuzzSettings/parallelize(lanes:)``).
///
/// - Important: This mode is experimental. Its settings, report format, and search behavior may change in any release; every call site emits a build warning until the mode stabilizes.
///
/// - Note: A spec's `failureDescription()` is not surfaced in `time:` mode; the reported counterexample is the reduced command sequence.
///
/// - Returns: A ``FuzzReport`` containing the clustered fault inventory, attempt counts, throughput, and coverage summary.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncStateMachineSpec>(
    _ specType: Spec.Type,
    time: TimeSpan,
    _ settings: FuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExecuteTimeAsyncMacro")

/// Runs an asynchronous spec test, dispatching to the `.tasks` or `.threads` runner based on the spec's ``ExecutionModel``.
///
/// For `.tasks` specs with async `@Command` methods, the cooperative scheduler controls interleaving deterministically at `await` boundaries. For `.threads` specs with async commands, commands are dispatched to real GCD threads with async execution bridged via `Task` + semaphore. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueBehavior() async {
///     let result = await #execute(ConcurrentQueueStateMachine.self, .parallelize(lanes: .two), .commandLimit(12))
/// }
/// ```
///
/// Settings are variadic ``StateMachineSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is <doc:StateMachineTesting>.
///
/// - Returns: A ``StateMachineResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncStateMachineSpec>(
    _ specType: Spec.Type,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncStateMachineMacro")
