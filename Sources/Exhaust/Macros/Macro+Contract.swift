// Macro declarations for contract-based property testing.
//
// `@Contract` synthesizes protocol conformance from annotated structs.
// `#exhaust(Spec.self, commandLimit: N)` runs a contract property test at the call site.
//
// The contract testing model draws on Hillel Wayne's work connecting
// contracts (preconditions, postconditions, invariants) with property-based
// testing. See: https://www.hillelwayne.com/post/pbt-contracts/
import ExhaustCore

/// Marks a struct as a contract specification, synthesizing protocol conformance, a command enum, and a command generator.
///
/// A contract defines the rules a system must obey under arbitrary sequences of operations. Three styles of contract are supported:
///
/// - **Model-based**: Compare the SUT against a reference model using `@Model` properties and `@Invariant` methods that assert equivalence.
/// - **Invariant-only**: Check structural properties of the SUT alone (for example, "the tree is always balanced") without a reference model.
/// - **Postcondition-only**: Use `check()` inside `@Command` methods to verify per-operation guarantees (for example, "after `add(x)`, `contains(x)` is true").
///
/// The struct must contain:
/// - Exactly one `@SUT` property (system under test).
/// - At least one `@Command` method (operations to test).
/// - Zero or more `@Model` properties (abstract state for model-based contracts).
/// - Zero or more `@Invariant` methods (postconditions checked after every step).
///
/// The macro synthesizes:
/// - A `Command` enum with one case per `@Command` method.
/// - A `commandGenerator` static property using `Gen.pick` with specified weights.
/// - A `run(_:)` method that dispatches commands to their methods.
/// - A `checkInvariants()` method that calls all `@Invariant` methods.
/// - Protocol conformance to ``ContractSpec``.
///
/// ## Model-Based Contract
///
/// ```swift
/// @Contract
/// struct BoundedQueueContract {
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
///
/// ## Invariant-Only Contract
///
/// ```swift
/// @Contract
/// struct SortedListContract {
///     @SUT var list = SortedList()
///
///     @Invariant
///     func alwaysSorted() -> Bool {
///         list.elements == list.elements.sorted()
///     }
///
///     @Command(weight: 3, .int(in: 0...99))
///     mutating func insert(value: Int) throws {
///         list.insert(value)
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
    named(sut),
    named(modelDescription),
    named(sutDescription)
)
@attached(extension, conformances: ContractSpec, AsyncContractSpec)
public macro Contract() = #externalMacro(module: "ExhaustMacros", type: "ContractDeclarationMacro")

/// Marks a property as model state in a `@Contract` struct.
///
/// Model properties represent the abstract state used to verify the system under test. They are included in `modelDescription` for failure reports. Model properties are optional — contracts can also use `@Invariant` and `check()` without a reference model.
@attached(peer)
public macro Model() = #externalMacro(module: "ExhaustMacros", type: "ModelMacro")

/// Marks a property as the system under test in a `@Contract` struct.
///
/// Exactly one `@SUT` property is required per state-machine specification. It is included in `sutDescription` for failure reports.
@attached(peer)
public macro SUT() = #externalMacro(module: "ExhaustMacros", type: "SUTMacro")

/// Marks a method as a command in a `@Contract` struct.
///
/// Each `@Command` method becomes a case in the synthesized `Command` enum. The macro's arguments control command generation:
///
/// - `weight`: Relative frequency for command selection (default 1). Higher weight means the command is selected more often.
/// - `#gen(...)`: Generators for the method's parameters. Must match the parameter count and types.
///
/// ```swift
/// @Command(weight: 3, .int(in: 0...99))
/// mutating func enqueue(value: Int) throws {
///     guard contents.count < 4 else { throw skip() }
///     queue.enqueue(value)
///     contents.append(value)
/// }
/// ```
@attached(peer)
public macro Command<each Generator>(weight: Int = 1, _ generators: repeat ReflectiveGenerator<each Generator>) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

/// Marks a method as a global postcondition in a `@Contract` struct.
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
