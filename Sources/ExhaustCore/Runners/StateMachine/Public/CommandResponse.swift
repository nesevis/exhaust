/// The return value of ``StateMachineSpec/run(_:)`` and ``AsyncStateMachineSpec/run(_:)``: a command's description paired with its return value.
///
/// Void-returning commands produce `nil` as the ``returnValue``. Both concurrent modes record these against the lane that ran the command, so a return value can be compared against a sequential replay. Sequential execution discards them.
///
/// A return type conforming to `Equatable` is compared with `==`. Any other type is compared structurally through reflection, which handles tuples and compound values but costs far more per comparison, and the linearizability search performs one comparison per replayed command. A type whose contents reflection cannot reach, such as a class exposing no stored properties, compares unequal to itself and reports a violation that did not occur.
///
/// Marked `@unchecked Sendable` because the value is consumed immediately by the caller after each command execution and never shared across isolation boundaries. Actor-isolation crossing in async spec runners is the only reason `Sendable` conformance is required.
public struct CommandResponse: @unchecked Sendable {
    /// A human-readable description of the command that produced this response.
    public let commandDescription: String

    /// The command's return value, or `nil` for void-returning commands.
    public let returnValue: Any?

    public init(commandDescription: String, returnValue: Any?) {
        self.commandDescription = commandDescription
        self.returnValue = returnValue
    }
}
