// Macro declarations for state-machine property testing.
//
// `@StateMachine` synthesizes protocol conformance from annotated structs.
// `#stateMachine` runs a state-machine property test at the call site.
import ExhaustCore

/// Runs a state-machine property test that generates command sequences, executes them against the system under test, and verifies model/SUT consistency.
///
/// ## How It Works
///
/// Three phases, executed in order:
///
/// **1. Structured coverage** (default budget: 2000 test cases). Builds a covering array over the command-type domain — each parameter is a position in the command sequence, each domain value is a command type. IPOG generates rows that guarantee every t-way ordered permutation of command types is tested.
///
/// **2. Random sampling** (default: 100 iterations). Generates random command sequences with weighted command selection.
///
/// **3. Test case reduction**. When a failing sequence is found, the existing Reducer strategies apply — deleting commands, simplifying arguments, reordering steps — until a minimal counterexample is found.
///
/// ## Settings
///
/// - `.sequenceLength(5...20)`: range of command sequence lengths (default 5...20).
/// - `.maxIterations(_)`: upper bound on random sampling iterations (default 100).
/// - `.coverageBudget(_)`: maximum test cases for structured coverage (default 2000).
/// - `.replay(_)`: fixed seed for deterministic reproduction.
/// - `.shrinkBudget(_)`: controls reduction aggressiveness.
/// - `.randomOnly`: disables structured coverage analysis.
///
/// ## Example
///
/// ```swift
/// @Test func boundedQueueBehavior() {
///     #stateMachine(BoundedQueueSpec.self, .sequenceLength(5...20))
/// }
/// ```
///
/// - Returns: A ``StateMachineResult`` containing the shrunk command sequence, execution trace, and SUT state if a violation is found, or `nil` if all sequences pass.
@freestanding(expression)
@discardableResult
public macro stateMachine<Spec: StateMachineSpec>(
    _ specType: Spec.Type,
    _ settings: StateMachineSettings...
) -> StateMachineResult<Spec>? = #externalMacro(module: "ExhaustMacros", type: "StateMachineMacro")

/// Marks a struct as a state-machine specification, synthesizing protocol conformance, a command enum, and a command generator.
///
/// The struct must contain:
/// - At least one `@Model` property (abstract state).
/// - Exactly one `@SUT` property (system under test).
/// - At least one `@Command` method (operations to test).
/// - Zero or more `@Invariant` methods (postconditions checked after every step).
///
/// The macro synthesizes:
/// - A `Command` enum with one case per `@Command` method.
/// - A `commandGenerator` static property using `Gen.pick` with specified weights.
/// - A `run(_:)` method that dispatches commands to their methods.
/// - A `checkInvariants()` method that calls all `@Invariant` methods.
/// - Protocol conformance to ``StateMachineSpec``.
///
/// ## Example
///
/// ```swift
/// @StateMachine
/// struct BoundedQueueSpec {
///     @Model var contents: [Int] = []
///     @SUT   var queue = BoundedQueue<Int>(capacity: 4)
///
///     @Invariant
///     func countMatches() -> Bool {
///         queue.count == contents.count
///     }
///
///     @Command(weight: 3, #gen(.int(in: 0...99)))
///     mutating func enqueue(value: Int) throws {
///         guard contents.count < 4 else { throw skip() }
///         queue.enqueue(value)
///         contents.append(value)
///     }
/// }
/// ```
@attached(member, names: named(Command), named(SystemUnderTest), named(commandGenerator), named(run), named(checkInvariants), named(sut), named(modelDescription), named(sutDescription))
@attached(extension, conformances: StateMachineSpec)
public macro StateMachine() = #externalMacro(module: "ExhaustMacros", type: "StateMachineDeclarationMacro")

/// Marks a property as model state in a `@StateMachine` struct.
///
/// Model properties represent the abstract state used to verify the system under test. They are included in `modelDescription` for failure reports.
@attached(peer)
public macro Model() = #externalMacro(module: "ExhaustMacros", type: "ModelMacro")

/// Marks a property as the system under test in a `@StateMachine` struct.
///
/// Exactly one `@SUT` property is required per state-machine specification. It is included in `sutDescription` for failure reports.
@attached(peer)
public macro SUT() = #externalMacro(module: "ExhaustMacros", type: "SUTMacro")

/// Marks a method as a command in a `@StateMachine` struct.
///
/// Each `@Command` method becomes a case in the synthesized `Command` enum. The macro's arguments control command generation:
///
/// - `weight`: Relative frequency for command selection (default 1). Higher weight means the command is selected more often.
/// - `#gen(...)`: Generators for the method's parameters. Must match the parameter count and types.
///
/// ```swift
/// @Command(weight: 3, #gen(.int(in: 0...99)))
/// mutating func enqueue(value: Int) throws {
///     guard contents.count < 4 else { throw skip() }
///     queue.enqueue(value)
///     contents.append(value)
/// }
/// ```
@attached(peer)
public macro Command(weight: Int = 1) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

/// Marks a method as a command with argument generators in a `@StateMachine` struct.
///
/// - Parameters:
///   - weight: Relative frequency for command selection (default 1).
///   - generators: One or more generators for the method's parameters, specified using the `#gen(...)` syntax.
@attached(peer)
public macro Command(weight: Int = 1, _ generators: Any...) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

/// Marks a method as a global postcondition in a `@StateMachine` struct.
///
/// Invariant methods are called after every command execution. They must return `Bool` — `true` for passing, `false` for failure. The method must be non-mutating.
///
/// ```swift
/// @Invariant
/// func countMatches() -> Bool {
///     queue.count == contents.count
/// }
/// ```
@attached(peer)
public macro Invariant() = #externalMacro(module: "ExhaustMacros", type: "InvariantMacro")
