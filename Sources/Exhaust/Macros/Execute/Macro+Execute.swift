// Macro declarations for running contract property tests with `#execute`.
//
// `#execute(MyContract.self, .settings...)` runs a contract spec at the call site, dispatching to the runner selected by the contract's `ExecutionModel`. The `@Contract` declaration macro and its markers live in `Macro+Contract.swift`.
import ExhaustCore

/// Runs a synchronous contract property test, dispatching to the `.sequential`, `.tasks`, or `.threads` runner based on the contract's ``ExecutionModel``.
///
/// `.sequential` and `.tasks` contracts run commands one at a time and check `@Invariant` after each step. A synchronous `.tasks` contract has no suspension points to interleave at, so it executes sequentially — use ``AsyncContractSpec`` (async commands) for cooperative interleaving. `.threads` dispatches commands across real GCD threads and checks the `@Oracle` against a sequential replay. On failure, the sequence is reduced to a minimal counterexample.
///
/// ```swift
/// @Test func boundedQueueBehavior() async {
///     await #execute(BoundedQueueContract.self, .commandLimit(20))
/// }
/// ```
///
/// ## Settings
///
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200).
/// - `.concurrent(_)`: number of concurrent execution lanes (one through four, default two). Only meaningful for `.threads` contracts.
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.idleTimeoutMs(_)`: maximum milliseconds the drain loop waits before declaring a timeout (default 2000). Only meaningful for concurrent contracts.
/// - `.onReport(_)`: registers a closure that receives an ``ExhaustReport`` after the test completes.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
/// - `.log(_)`: controls log verbosity. Defaults to `.error`.
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
///     let result = await #execute(ConcurrentQueueContract.self, .concurrent(.two), .commandLimit(12))
/// }
/// ```
///
/// ## Settings
///
/// - `.concurrent(_)`: number of concurrent execution lanes (one through four, default two).
/// - `.commandLimit(_)`: maximum commands per generated sequence. Reduction may produce shorter sequences.
/// - `.budget(_)`: iteration budgets for coverage and sampling. Defaults to `.standard` (200/200).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.idleTimeoutMs(_)`: maximum milliseconds the drain loop waits before declaring a timeout (default 2000).
/// - `.onReport(_)`: registers a closure that receives an ``ExhaustReport`` after the test completes.
/// - `.suppress(.issueReporting)`: skips `reportIssue()` — useful when the caller asserts on the returned value.
/// - `.suppress(.logs)`: silences all console output.
/// - `.log(_)`: controls log verbosity. Defaults to `.error`.
///
/// - Returns: A ``ContractResult`` containing the reduced command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro execute<Spec: AsyncContractSpec>(
    _ specType: Spec.Type,
    _ settings: ContractSettings...
) -> ContractResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "ExhaustAsyncContractMacro")
