/// Captures diagnostic state from a contract for failure reports.
///
/// For actor contracts, these properties can only be read from the actor's executor. ``AsyncContractSpec/diagnosticSnapshot()`` provides an async entry point that hops correctly.
public struct DiagnosticSnapshot<SystemUnderTest>: @unchecked Sendable {
    public let systemUnderTest: SystemUnderTest
    public let failureDescription: String

    public init(systemUnderTest: SystemUnderTest, failureDescription: String) {
        self.systemUnderTest = systemUnderTest
        self.failureDescription = failureDescription
    }
}
