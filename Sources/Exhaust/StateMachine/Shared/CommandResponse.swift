/// The return value of ``StateMachineSpec/run(_:)`` and ``AsyncStateMachineSpec/run(_:)``: a command's description paired with its return value.
///
/// Void-returning commands produce `nil` as the ``returnValue``. The preemptive runner captures these per-lane for linearizability confirmation. Sequential and cooperative runners discard them.
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
