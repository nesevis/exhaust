// Macro declarations for running spec tests with `#execute`.
//
// `#execute(MySpec.self, mode: .sequential, .settings...)` runs a spec test at the call site. The `@StateMachine` declaration macro and its markers live in `Macro+StateMachine.swift`. Time-budgeted spec search is spelled `#explore(MySpec.self, mode:, time:)` and lives in `Macro+Explore.swift`, alongside the generator form it shares its report type with.
//
// `mode:` is required rather than defaulted, and there is no overload without it. Every other setting changes how hard a run tries; the mode changes which property it checks, and the value a default would pick is the weakest of the three. Omitting it on a spec whose commands are async would produce a run that executes, tests strictly less than the author meant, and passes — with nothing able to tell a deliberate `.sequential` from a forgotten one. Requiring it also keeps the mode written exactly once somewhere, which is what `@StateMachine(.sequential)` used to guarantee before the mode moved to the call site.
import ExhaustCore

/// Runs a synchronous spec test under the given ``ExecutionModel``.
///
/// `mode: .sequential` runs the commands in the order generated, with `@Invariant` checked after each. `mode: .threads` dispatches them across real OS threads and judges the run through the spec's `@Equivalence`, comparing it against a sequential replay. `mode: .tasks` on a synchronous spec also runs one command at a time, because interleaving happens at `await` boundaries a synchronous spec does not have. Interleaving under `.tasks` requires a spec conforming to ``AsyncStateMachineSpec``. On failure, the sequence is reduced to a minimal counterexample.
///
/// Always awaited: the test function must be `async` even when every command is synchronous.
///
/// ```swift
/// @Test func boundedQueueBehavior() async {
///     await #execute(BoundedQueueSpec.self, mode: .sequential, .commandLimit(20))
/// }
///
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

/// Runs an asynchronous spec test under the given ``ExecutionModel``.
///
/// `mode: .sequential` awaits each command and invariant check in turn. `mode: .tasks` interleaves the commands deterministically at every `await` boundary, with the interleaving drawn as part of the generated input so a seed reproduces it and reduction minimizes it. `mode: .threads` dispatches them across real OS threads instead, bridging each command's async execution, and judges the run through the spec's `@Equivalence`. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueBehavior() async {
///     await #execute(ConcurrentQueueSpec.self, mode: .sequential, .commandLimit(12))
/// }
///
/// @Test func concurrentQueueInterleavings() async {
///     await #execute(ConcurrentQueueSpec.self, mode: .tasks, .commandLimit(12))
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
