// Macro declarations for state-machine property testing.
//
// `@Contract` synthesizes protocol conformance from annotated structs.
// `#exhaust(Spec.self)` runs a state-machine property test at the call site.
import ExhaustCore

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
/// - Protocol conformance to ``ContractSpec``.
///
/// ## Example
///
/// ```swift
/// @Contract
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
@attached(extension, conformances: ContractSpec)
public macro Contract() = #externalMacro(module: "ExhaustMacros", type: "ContractDeclarationMacro")

/// Marks a property as model state in a `@Contract` struct.
///
/// Model properties represent the abstract state used to verify the system under test. They are included in `modelDescription` for failure reports.
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
/// @Command(weight: 3, #gen(.int(in: 0...99)))
/// mutating func enqueue(value: Int) throws {
///     guard contents.count < 4 else { throw skip() }
///     queue.enqueue(value)
///     contents.append(value)
/// }
/// ```
@attached(peer)
public macro Command(weight: Int = 1) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

/// Marks a method as a command with argument generators in a `@Contract` struct.
///
/// - Parameters:
///   - weight: Relative frequency for command selection (default 1).
///   - generators: One or more generators for the method's parameters, specified using the `#gen(...)` syntax.
@attached(peer)
public macro Command(weight: Int = 1, _ generators: Any...) = #externalMacro(module: "ExhaustMacros", type: "CommandMacro")

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
