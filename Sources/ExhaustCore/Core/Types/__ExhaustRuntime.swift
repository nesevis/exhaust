/// Provides runtime support for `#exhaust`, `#explore`, and `#examine` macro expansions.
///
/// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`) to signal that this is macro infrastructure, not public API.
public enum __ExhaustRuntime { // swiftlint:disable:this type_name
    /// Maximum number of filter retry attempts before giving up on a single value.
    public static var maxFilterRuns: UInt64 {
        500
    }

    @TaskLocal private static var _isInterpreting: Bool = false

    /// Whether the generation pipeline is currently interpreting a generator tree.
    public static var isInterpreting: Bool {
        _isInterpreting
    }

    /// Executes `operation` with ``isInterpreting`` set to the given value for the current task.
    public static func withIsInterpreting<Result>(
        _ value: Bool,
        operation: () throws -> Result
    ) rethrows -> Result {
        try $_isInterpreting.withValue(value, operation: operation)
    }
}
