// Macro declarations for running spec tests with `#execute`.
//
// `#execute(MySpec.self, .settings...)` runs a spec spec at the call site, dispatching to the runner selected by the spec's `ExecutionModel`. The `@StateMachine` declaration macro and its markers live in `Macro+StateMachine.swift`.
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
/// Settings are variadic ``StateMachineSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is docs/EXECUTE-spec-testing.md.
///
/// - Returns: A ``StateMachineResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustStateMachineMacro")

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
/// Settings are variadic ``StateMachineSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is docs/EXECUTE-spec-testing.md.
///
/// - Returns: A ``StateMachineResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncStateMachineSpec>(
    _ specType: Spec.Type,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncStateMachineMacro")
