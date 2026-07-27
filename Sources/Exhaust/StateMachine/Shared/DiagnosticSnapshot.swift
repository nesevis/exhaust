/// Captures diagnostic state from a spec for failure reports.
///
/// Exists to carry the system under test and failure description across the runner's Task-plus-semaphore bridge. `@unchecked Sendable` is safe because the bridge hands the value to exactly one waiter after the producing Task has finished with it.
public struct DiagnosticSnapshot<SystemUnderTest>: @unchecked Sendable {
    public let systemUnderTest: SystemUnderTest
    public let failureDescription: String?

    public init(systemUnderTest: SystemUnderTest, failureDescription: String?) {
        self.systemUnderTest = systemUnderTest
        self.failureDescription = failureDescription
    }
}
