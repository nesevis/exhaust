// Macro declarations for state machine spec testing.
//
// `@StateMachine(.tasks)` or `@StateMachine(.threads)` synthesizes protocol conformance.
// `#execute(MySpec.self, .commandLimit(N))` runs a spec test at the call site.
//
import ExhaustCore

/// Marks a `final class` or `actor` as a spec, synthesizing protocol conformance, a command enum, and a command generator.
///
/// The required ``ExecutionModel`` argument selects the execution model:
///
/// - `.sequential` runs commands one at a time. Checks use `@Invariant`.
/// - `.tasks` runs commands concurrently with deterministic interleaving at `await` boundaries. Checks use `@Invariant`.
/// - `.threads` dispatches commands to real OS threads via GCD. Checks use `@Oracle`, which compares the concurrent end state against a sequential replay.
///
/// ## .tasks StateMachine
///
/// Commands must be `async` for `.tasks` to have suspension points to interleave at. Without `await` boundaries, `.tasks` behaves identically to `.sequential`. The SUT below has a deliberate read-yield-write race: two overlapping increments read the same value, suspend, and both write `current + 1`, losing one update.
///
/// ```swift
/// @StateMachine(.tasks)
/// final class NonAtomicCounterSpec {
///     var expected: Int = 0
///     @SystemUnderTest
///     var counter: NonAtomicCounter = .init()
///
///     @Invariant
///     func matchesModel() -> Bool {
///         counter.value == expected
///     }
///
///     @Command(weight: 3)
///     func increment() async throws {
///         expected += 1
///         await counter.increment()
///     }
///
///     @Command(weight: 2)
///     func decrement() async throws {
///         guard expected > 0 else { throw skip() }
///         expected -= 1
///         await counter.decrement()
///     }
///
///     func failureDescription() -> String? {
///         "\(counter)"
///     }
/// }
///
/// final class NonAtomicCounter: @unchecked Sendable {
///     private var _value: Int = 0
///     var value: Int { _value }
///
///     func increment() async {
///         let current = _value
///         await Task.yield()
///         _value = current + 1
///     }
///
///     func decrement() async {
///         let current = _value
///         await Task.yield()
///         _value = current - 1
///     }
/// }
/// ```
///
/// ## .threads StateMachine (Oracle-Based)
///
/// ```swift
/// @StateMachine(.threads)
/// final class CounterThreadSafetyStateMachine {
///     @SystemUnderTest var counter = Counter()
///
///     @Oracle
///     func equivalent(to other: Counter) -> Bool {
///         counter.value == other.value
///     }
///
///     @Command(weight: 3)
///     func increment() { counter.increment() }
///
///     @Command
///     func decrement() { counter.decrement() }
///
///     func failureDescription() -> String? {
///         "counter: \(counter)"
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
    named(init),
    named(executionModel),
    named(diagnosticSnapshot)
)
@attached(extension, conformances: StateMachineSpec, AsyncStateMachineSpec)
public macro StateMachine(_ mode: ExecutionModel) = #externalMacro(module: "ExhaustMacros", type: "StateMachineDeclarationMacro")

/// Marks a property as the system under test in a spec.
///
/// Exactly one `@SystemUnderTest` property is required per spec. Its type is exposed as the spec's `SystemUnderTest` associated type in the ``StateMachineResult``, and its description is included in failure reports.
@attached(peer)
public macro SystemUnderTest() = #externalMacro(module: "ExhaustMacros", type: "SUTMacro")

/// Marks a method as a command in a spec.
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

/// Marks a method as a global postcondition in a spec.
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

/// Marks a method as the oracle comparison in a `@StateMachine(.threads)` class.
///
/// The oracle method receives a second SUT instance (the sequential replay result) and returns whether the concurrent SUT state is equivalent. The method must take one parameter of the `SystemUnderTest` type and return `Bool`.
///
/// ```swift
/// @Oracle
/// func equivalent(to other: ConcurrentQueue<Int>) -> Bool {
///     queue.count == other.count && Set(queue.elements) == Set(other.elements)
/// }
/// ```
@attached(peer)
public macro Oracle() = #externalMacro(module: "ExhaustMacros", type: "OracleMacro")
