// Macro declarations for running contract property tests with `#execute`.
//
// `#execute(MyContract.self, .settings...)` runs a contract spec at the call site, dispatching to the runner selected by the contract's `ExecutionModel`. The `@Contract` declaration macro and its markers live in `Macro+Contract.swift`.
import ExhaustCore

/// Runs a synchronous contract property test, dispatching to the `.sequential`, `.tasks`, or `.threads` runner based on the contract's ``ExecutionModel``.
///
/// `.sequential` and `.tasks` contracts run commands one at a time and check `@Invariant` after each step. A synchronous `.tasks` contract has no suspension points to interleave at, so it executes sequentially. Cooperative interleaving requires async commands (``AsyncContractSpec``). `.threads` dispatches commands across real GCD threads and checks the `@Oracle` against a sequential replay. On failure, the sequence is reduced to a minimal counterexample. Always awaited: the test function must be `async` even when every command is synchronous.
///
/// ```swift
/// @Test func boundedQueueBehavior() async {
///     await #execute(BoundedQueueContract.self, .commandLimit(20))
/// }
/// ```
///
/// Settings are variadic ``ContractSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is docs/EXECUTE-contract-testing.md.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: ContractSpec>(
    _ specType: Spec.Type,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustContractMacro")

/// Runs an asynchronous contract property test, dispatching to the `.tasks` or `.threads` runner based on the contract's ``ExecutionModel``.
///
/// For `.tasks` contracts with async `@Command` methods, the cooperative scheduler controls interleaving deterministically at `await` boundaries. For `.threads` contracts with async commands, commands are dispatched to real GCD threads with async execution bridged via `Task` + semaphore. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func concurrentQueueBehavior() async {
///     let result = await #execute(ConcurrentQueueContract.self, .parallelize(lanes: .two), .commandLimit(12))
/// }
/// ```
///
/// Settings are variadic ``ContractSettings`` values controlling command limits, budgets (``ExhaustBudget``), lane count, deterministic replay, timeouts, output suppression, and diagnostics. Each case documents itself. The full guide is docs/EXECUTE-contract-testing.md.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncContractMacro")
