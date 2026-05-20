/// Describes a type that can be losslessly represented by a ``UInt64`` bit pattern.
///
/// Without this protocol, each numeric type would need its own generator and reduction logic instead of sharing the unified ``Gen/choose(in:)`` path. Any type that conforms (for example, ``Int`` and ``Float``) gets ``Gen/choose(in:)`` support automatically.
/// Returns whether the given value is at its type's semantic simplest bit pattern.
///
/// Attempts to cast the value to each ``BitPatternConvertible`` conformer and compares its ``BitPatternConvertible/bitPattern64`` against ``TypeTag/simplestBitPattern``. Returns `nil` when the value is not a recognized ``BitPatternConvertible`` type.
package func isAtSemanticSimplest(_ value: Any) -> Bool? {
    func check<T: BitPatternConvertible>(_ value: Any, as _: T.Type) -> Bool? {
        guard let typed = value as? T else { return nil }
        return typed.bitPattern64 == T.tag.simplestBitPattern
    }
    if let result = check(value, as: Int.self) { return result }
    if let result = check(value, as: Int8.self) { return result }
    if let result = check(value, as: Int16.self) { return result }
    if let result = check(value, as: Int32.self) { return result }
    if let result = check(value, as: Int64.self) { return result }
    if let result = check(value, as: UInt.self) { return result }
    if let result = check(value, as: UInt8.self) { return result }
    if let result = check(value, as: UInt16.self) { return result }
    if let result = check(value, as: UInt32.self) { return result }
    if let result = check(value, as: UInt64.self) { return result }
    if let result = check(value, as: Double.self) { return result }
    if let result = check(value, as: Float.self) { return result }
    return nil
}

package protocol BitPatternConvertible: Equatable, Sendable {
    /// The valid range of this type, expressed as an inclusive ``ClosedRange`` of ``UInt64`` bit patterns. This is used by ``Gen/choose(in:)`` as the default range if a more specific one is not provided.
    static var bitPatternRange: ClosedRange<UInt64> { get }

    /// Provides the type metadata used by coverage analysis, boundary value analysis, and the human-readable type formatter.
    static var tag: TypeTag { get }

    /// Creates an instance of this type from a raw ``UInt64`` bit pattern. This is the core decoding step used by the generator's continuation.
    init(bitPattern64: UInt64)

    /// Provides the raw ``UInt64`` bit pattern for this specific instance. This is the core encoding step used by the reflect interpreter.
    var bitPattern64: UInt64 { get }

    /// The preferred size-scaling distribution for this type when used with ``Gen/choose(in:scaling:)``. Override to control how ``arbitrary`` generators expand their range as the size parameter grows.
    static var defaultScaling: SizeScaling<Self> { get }
}
