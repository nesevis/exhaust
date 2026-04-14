/// Describes a type that can be losslessly represented by a `UInt64` bit pattern.
///
/// This protocol is the foundation for the unified ``Gen/choose(in:)`` generator, allowing it to work generically over any conforming type (for example, `Int`, `Float`, `Character`).
public protocol BitPatternConvertible: Equatable, Sendable {
    /// The valid range of this type, expressed as an inclusive `ClosedRange` of `UInt64` bit patterns. This is used by ``Gen/choose(in:)`` as the default range if a more specific one is not provided.
    static var bitPatternRange: ClosedRange<UInt64> { get }

    /// Provides the type metadata used by coverage analysis, boundary value analysis, and the human-readable type formatter.
    static var tag: TypeTag { get }

    /// Creates an instance of this type from a raw `UInt64` bit pattern.
    /// This is the core decoding step used by the generator's `continuation`.
    init(bitPattern64: UInt64)

    /// Provides the raw `UInt64` bit pattern for this specific instance.
    /// This is the core encoding step used by the `reflect` interpreter.
    var bitPattern64: UInt64 { get }

    /// The preferred size-scaling distribution for this type when used with ``Gen/choose(in:scaling:)``. Override to control how `arbitrary` generators expand their range as the size parameter grows.
    static var defaultScaling: SizeScaling<Self> { get }
}
