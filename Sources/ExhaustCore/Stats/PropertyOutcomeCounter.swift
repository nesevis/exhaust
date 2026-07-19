/// Wraps a property closure and counts its invocations and failures for ``RunLedger`` recording.
///
/// Reduction paths probe the property through closures the reducer owns, so the probe site cannot record outcomes directly; this counter is the single place the count-the-call, count-the-failure bookkeeping lives instead of being open-coded at every probe site. Reference semantics so the reducer's captured copy and the recording site observe the same counts.
package final class PropertyOutcomeCounter<Output> {
    private let property: (Output) -> Bool

    /// The number of times the wrapped property ran.
    package private(set) var invocations = 0

    /// The number of runs that returned `false`.
    package private(set) var failures = 0

    package init(_ property: @escaping (Output) -> Bool) {
        self.property = property
    }

    /// Runs the wrapped property, recording the invocation and its outcome, and returns the property's verdict unchanged.
    package func callAsFunction(_ value: Output) -> Bool {
        invocations += 1
        let passed = property(value)
        if passed == false {
            failures += 1
        }
        return passed
    }
}
