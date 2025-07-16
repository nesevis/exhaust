/// Describes a type that can be losslessly represented by a `UInt64` bit pattern.
///
/// This protocol is the foundation for the unified `choose` generator, allowing it
/// to work generically over any conforming type (e.g., `Int`, `Float`, `Character`).
protocol BitPatternConvertible: Equatable {
    /// The valid range of this type, expressed as an inclusive `ClosedRange`
    /// of `UInt64` bit patterns. This is used by `choose()` as the default range
    /// if a more specific one is not provided.
    static var bitPatternRange: ClosedRange<UInt64> { get }

    /// Creates an instance of this type from a raw `UInt64` bit pattern.
    /// This is the core decoding step used by the generator's `continuation`.
    init(bitPattern: UInt64)

    /// Provides the raw `UInt64` bit pattern for this specific instance.
    /// This is the core encoding step used by the `reflect` interpreter.
    var bitPattern64: UInt64 { get }
}
