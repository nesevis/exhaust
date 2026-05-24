/// Provides runtime support for `#exhaust`, `#explore`, and `#examine` macro expansions.
///
/// The `__` prefix follows Swift Testing's convention (`Testing.__check`, `Testing.__Expression`) to signal that this is macro infrastructure, not public API.
public enum __ExhaustRuntime { // swiftlint:disable:this type_name
    /// Maximum number of filter retry attempts before giving up on a single value.
    public static let maxFilterRuns: UInt64 = 500

    /// Set by the generation pipeline to signal that ``.filter`` is being constructed during interpretation (inside a bind continuation) rather than at top level. When true, ``.filter`` defers CGS tuning to the interpreter's fingerprint-keyed cache instead of tuning eagerly.
    @TaskLocal public static var isInterpreting: Bool = false
}
