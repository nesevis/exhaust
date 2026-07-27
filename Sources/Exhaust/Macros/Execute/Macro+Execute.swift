// Macro declarations for running spec tests with `#execute`.
//
// `#execute(MySpec.self, .settings...)` runs a spec test at the call site; the `mode:` overloads choose how its commands run. The `@StateMachine` declaration macro and its markers live in `Macro+StateMachine.swift`.
//
// Each mode-taking overload is a separate declaration rather than a defaulted parameter: a defaulted labelled parameter sitting immediately before an unlabelled variadic breaks argument completion, and the settings variadic is what a reader types most.
import ExhaustCore

/// Runs a synchronous spec test, one command at a time.
///
/// Commands run in the order generated, with `@Invariant` checked after each. On failure, the sequence is reduced to a minimal counterexample. Always awaited: the test function must be `async` even when every command is synchronous.
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

/// Runs a synchronous spec test under the given ``ExecutionModel``.
///
/// `mode: .threads` dispatches the commands across real OS threads and judges the run through the spec's `@Equivalence`, comparing it against a sequential replay. `mode: .tasks` on a synchronous spec runs one command at a time, because interleaving happens at `await` boundaries a synchronous spec does not have; use the ``AsyncStateMachineSpec`` overload for that. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func counterIsThreadSafe() async {
///     await #execute(CounterSpec.self, mode: .threads, .commandLimit(10))
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
    mode: ExecutionModel,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustStateMachineMacro")

/// Runs an asynchronous spec test, one command at a time.
///
/// Each command and invariant check is awaited in turn. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueBehavior() async {
///     await #execute(ConcurrentQueueSpec.self, .commandLimit(12))
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

/// Runs an asynchronous spec test under the given ``ExecutionModel``.
///
/// `mode: .tasks` interleaves the commands deterministically at every `await` boundary, with the interleaving drawn as part of the generated input so a seed reproduces it and reduction minimizes it. `mode: .threads` dispatches them across real OS threads instead, bridging each command's async execution, and judges the run through the spec's `@Equivalence`. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueInterleavings() async {
///     await #execute(ConcurrentQueueSpec.self, mode: .tasks, .parallelize(lanes: .two), .commandLimit(12))
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
    mode: ExecutionModel,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncStateMachineMacro")

/// Runs a coverage-guided spec test that mutates command sequences from a corpus toward novel SUT coverage until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
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

/// Runs a coverage-guided spec test under the given ``ExecutionModel`` until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `mode: .tasks` on a synchronous spec runs one command at a time, because interleaving needs `await` boundaries. The mode is a ``SearchableExecutionModel``, which has no `.threads`: coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay. Run those specs under plain `#execute`, whose race detection relies on repetition rather than coverage.
///
/// ```swift
/// @Test func boundedQueueFuzz() async {
///     await #execute(BoundedQueueSpec.self, mode: .sequential, time: .minutes(5))
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
    mode: SearchableExecutionModel,
    time: TimeSpan,
    _ settings: FuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExecuteTimeMacro")

/// Runs a coverage-guided spec test for an async spec that mutates command sequences from a corpus toward novel SUT coverage until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// Commands run one at a time, each awaited in turn. To search interleavings as well, use the overload that takes a `mode:`.
///
/// ```swift
/// @Test func concurrentQueueFuzz() async {
///     await #execute(ConcurrentQueueSpec.self, time: .minutes(5))
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

/// Runs a coverage-guided spec test for an async spec under the given ``ExecutionModel`` until the time budget is consumed.
///
/// Requires coverage instrumentation on the target under test; without it the test fails immediately with the compiler flags to add, before any budget is consumed. The run skips the covering-array screening phase and begins with random sampling, then spends the remaining budget in the mutation phase: exploration from corpus parents guided by branch-coverage feedback. Failures are cataloged and clustered rather than terminating the run.
///
/// `mode: .tasks` drains each sequence through the cooperative scheduler: every command carries a lane-assigning schedule marker drawn as part of the generated input, so the interleaving itself is searched, mutated, and reduced alongside the commands (``FuzzSettings/parallelize(lanes:)`` sets the lane count, defaulting to two). It requires macOS 15, iOS 18, tvOS 18, watchOS 11, or visionOS 2. The mode is a ``SearchableExecutionModel``, which has no `.threads`: coverage novelty assumes an attempt's coverage follows from its command sequence, and preemptive scheduling makes it follow from an OS schedule the run can neither observe nor replay. Run those specs under plain `#execute`, whose race detection relies on repetition rather than coverage.
///
/// ```swift
/// @Test func concurrentQueueFuzz() async {
///     await #execute(ConcurrentQueueSpec.self, mode: .tasks, time: .minutes(5), .parallelize(lanes: .two))
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
    mode: SearchableExecutionModel,
    time: TimeSpan,
    _ settings: FuzzSettings...
) -> FuzzReport = #externalMacro(module: "ExhaustMacros", type: "ExecuteTimeAsyncMacro")
