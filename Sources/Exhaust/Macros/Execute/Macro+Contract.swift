// Macro declarations for contract-based property testing.
//
// `@Contract(.tasks)` or `@Contract(.threads)` synthesizes protocol conformance.
// `#execute(MyContract.self, .commandLimit(N))` runs a contract property test at the call site.
//
import ExhaustCore

/// Marks a `final class` or `actor` as a contract, synthesizing protocol conformance, a command enum, and a command generator.
///
/// The required ``ExecutionModel`` argument selects the execution model:
///
/// - `.sequential` runs commands one at a time. Checks use `@Invariant`.
/// - `.tasks` runs commands concurrently with deterministic interleaving at `await` boundaries. Checks use `@Invariant`.
/// - `.threads` dispatches commands to real OS threads via GCD. Checks use `@Oracle`, which compares the concurrent end state against a sequential replay.
///
/// ## `.tasks` Contract
///
/// ```swift
/// @Contract(.tasks)
/// final class BoundedQueueContract {
///     var contents: [Int] = []
///     @SystemUnderTest
///     var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Invariant
///     func countMatches() -> Bool {
///         queue.count == contents.count
///     }
///
///     @Command(weight: 3, #gen(.int(in: 0...99)))
///     func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
///     }
///
///     func failureDescription() -> String {
///         "expected: \(contents), queue: \(queue)"
///     }
/// }
/// ```
///
/// ## `.threads` Contract (Oracle-Based)
///
/// ```swift
/// @Contract(.threads)
/// final class CounterThreadSafetyContract {
///     @SystemUnderTest var counter = Counter()
///
///     @Command(weight: 3)
///     func increment() { counter.increment() }
///
///     @Command
///     func decrement() { counter.decrement() }
///
///     @Oracle
///     func equivalent(to other: Counter) -> Bool {
///         counter.value == other.value
///     }
/// }
/// ```
@attached(
    member,
    names:
    named(Command),
    named(SystemUnderTest),
    named(commandGenerator),
    named(run),
    named(checkInvariants),
    named(oracleCheck),
    named(systemUnderTest),
    named(failureDescription),
    named(init),
    named(executionModel),
    named(diagnosticSnapshot)
)
@attached(extension, conformances: ContractSpec, AsyncContractSpec)
public macro Contract(_ mode: ExecutionModel) = #externalMacro(module: "ExhaustMacros", type: "ContractDeclarationMacro")

/// Marks a property as the system under test in a contract.
///
/// Exactly one `@SystemUnderTest` property is required per contract. Its type is exposed as the contract's `SystemUnderTest` associated type in the ``ContractResult``, and its description is included in failure reports.
@attached(peer)
public macro SystemUnderTest() = #externalMacro(module: "ExhaustMacros", type: "SUTMacro")

/// Marks a method as a command in a contract.
///
/// Each `@Command` method becomes a case in the synthesized `Command` enum. The macro's arguments control command generation:
///
/// - `weight`: Relative frequency for command selection (default 1). Higher weight means the command is selected more often.
/// - Generators for the method's parameters, passed as trailing variadic arguments. Must match the parameter count and types.
///
/// ```swift
/// @Command(weight: 3, .int(in: 0...99))
/// func enqueue(value: Int) throws {
///     guard contents.count < 4 else { throw skip() }
///     queue.enqueue(value)
///     contents.append(value)
/// }
/// ```
@attached(peer)
public macro Command<each Generator>(weight: Int = 1, _ generators: repeat ReflectiveGenerator<each Generator>) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

/// Marks a method as a global postcondition in a contract.
///
/// Invariant methods are called after every command execution. They must return `Bool`: `true` for passing, `false` for failure.
///
/// ```swift
/// @Invariant
/// func countMatches() -> Bool {
///     queue.count == contents.count
/// }
/// ```
@attached(peer)
public macro Invariant() = #externalMacro(module: "ExhaustMacros", type: "InvariantMacro")

/// Marks a method as the oracle comparison in a `@Contract(.threads)` class.
///
/// The oracle method receives a second SUT instance (the sequential replay result) and returns whether the concurrent SUT state is equivalent. The method must take one parameter of the ``SystemUnderTest`` type and return `Bool`.
///
/// ```swift
/// @Oracle
/// func equivalent(to other: ConcurrentQueue<Int>) -> Bool {
///     queue.count == other.count && Set(queue.elements) == Set(other.elements)
/// }
/// ```
@attached(peer)
public macro Oracle() = #externalMacro(module: "ExhaustMacros", type: "OracleMacro")
