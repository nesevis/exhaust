// Macro declarations for state machine spec testing.
//
// `@StateMachine` synthesizes protocol conformance; `#execute(MySpec.self, mode:, .commandLimit(N))` runs a spec test at the call site and chooses how the commands run.
//
import ExhaustCore

/// Marks a `final class` as a spec, synthesizing protocol conformance, a command enum, and a command generator.
///
/// One spec shape runs under every execution mode. A `@Command` body updates the model and calls the system under test together, `@Invariant` states what holds whatever order the commands ran in, and `@Equivalence` states what "the same result" means when the order can vary. The mode is a `#execute` argument, so turning the dial needs no change to the spec:
///
/// ```swift
/// @StateMachine
/// final class CounterSpec {
///     var expected: Int = 0
///     @SystemUnderTest
///     var counter: NonAtomicCounter = .init()
///
///     @Invariant
///     func matchesModel() -> Bool {
///         counter.value == expected
///     }
///
///     @Command(weight: 1)
///     func increment() async throws {
///         expected += 1
///         await counter.increment()
///     }
///
///     func failureDescription() -> String? {
///         "expected \(expected), counter \(counter.value)"
///     }
/// }
///
/// await #execute(CounterSpec.self, mode: .sequential)                // one command at a time
/// await #execute(CounterSpec.self, mode: .tasks, .commandLimit(6))   // interleaved at every await
/// await #execute(CounterSpec.self, mode: .threads)                   // real OS threads
/// ```
///
/// Which claim belongs where is the one decision worth pausing on: could a different valid order change this check's answer? Then it is not an invariant, and it belongs in the equivalence. Two increments commute, so `counter.value == expected` is a true invariant. Two writes to one register do not, so that comparison is an equivalence.
///
/// A spec may also declare one ``Setup(_:)`` method, whose parameters Exhaust generates, when the starting configuration should vary from run to run rather than being fixed in `init()`.
///
/// - Note: `mode: .threads` runs every lane's commands concurrently on one shared spec instance, so the system under test is expected to defend itself — that is the claim under test — and any other spec state a command body touches must be thread-safe or absent. It also requires an `@Equivalence` and a reference-typed system under test, both reported at the start of the run.
@attached(
    member,
    names:
    named(Command),
    named(SystemUnderTest),
    named(commandGenerator),
    named(run),
    named(checkInvariants),
    named(equivalenceCheck),
    named(hasEquivalence),
    named(systemUnderTest),
    named(init),
    named(SetupStep),
    named(setupGenerator),
    named(runSetup)
)
@attached(extension, conformances: StateMachineSpec, AsyncStateMachineSpec)
public macro StateMachine() = #externalMacro(module: "ExhaustMacros", type: "StateMachineDeclarationMacro")

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

/// Marks a method as the generated setup step in a spec.
///
/// The setup method runs once per fresh spec instance, before any command, with values drawn from the attribute's generators. Use it when the spec's starting configuration should be generated rather than fixed: its values replay from seeds and reduce with the counterexample, the same way a `@Command` method's arguments do. Fixed, non-generated construction belongs in `init()` instead, which is cheaper because setup runs on every probe.
///
/// A spec allows at most one `@Setup` method. Multi-phase setup merges into one method whose body runs the phases in order. Setup cannot skip, reduction never deletes it, and no invariant check runs after it; a setup throw fails the run.
///
/// ```swift
/// @Setup(.int(in: 1 ... 32), .int(in: 0 ... 9).array(length: 0 ... 8))
/// func configure(capacity: Int, preload: [Int]) {
///     queue = BoundedQueue(capacity: capacity)
///     for value in preload where queue.enqueue(value) {
///         model.append(value)
///     }
/// }
/// ```
///
/// - Note: A `@SystemUnderTest` property only needs to be optional or implicitly unwrapped when the SUT's own construction consumes generated values. A setup that mutates an already-constructed SUT keeps a non-optional property with its default initializer.
@attached(peer)
public macro Setup<each Generator>(_ generators: repeat ReflectiveGenerator<each Generator>) = #externalMacro(module: "ExhaustMacros", type: "SetupMacro")

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

/// Marks a method as the spec's definition of "the same result" for a concurrent run.
///
/// Exhaust re-runs the commands sequentially and hands the method that replay's system under test; returning `true` accepts the concurrent run as equivalent to it. Use this for a claim whose answer depends on the order commands ran in, which an `@Invariant` cannot express. The method takes one parameter of the `SystemUnderTest` type and returns `Bool`.
///
/// A rejection is not yet a counterexample: the comparison is against one fixed order, so Exhaust then searches the orders the run could actually have taken, and reports a failure only when none of them explains what the commands observed.
///
/// Required under `mode: .threads`, optional under `mode: .tasks`, and never called under `mode: .sequential`, where there is only one order for the run to have taken.
///
/// ```swift
/// @Equivalence
/// func equivalent(to other: ConcurrentQueue<Int>) -> Bool {
///     queue.count == other.count && Set(queue.elements) == Set(other.elements)
/// }
/// ```
@attached(peer)
public macro Equivalence() = #externalMacro(module: "ExhaustMacros", type: "EquivalenceMacro")
