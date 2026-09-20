#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Exhaustable
import ExhaustCore

extension DefaultGenerable {
    static func defaultGenerator(domain _: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        defaultGenerator
    }
}

extension DefaultGenerable where Self: FixedWidthInteger & BitPatternConvertible {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let magnitude = domain.numericMagnitude else {
            return defaultGenerator
        }
        let range = Self(clamping: -magnitude) ... Self(clamping: magnitude)
        return boundedInteger(in: range)
    }
}

extension DefaultGenerable where Self: BinaryFloatingPoint & BitPatternConvertible {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let magnitude = domain.numericMagnitude else {
            return defaultGenerator
        }
        let bound = Self(magnitude)
        return Gen.chooseDerived(in: -bound ... bound, scaling: .linear).wrapped(isReflective: true)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension Int128 {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let magnitude = domain.numericMagnitude else {
            return defaultGenerator
        }
        let bits = boundedWideBits(maximumGeneratedValue: UInt64(magnitude * 2))
        return bits.mapped(
            forward: { encoded in
                Int128(bitPattern: encoded >> 1) ^ -Int128(encoded & 1)
            },
            backward: { value in
                let bits = UInt128(bitPattern: value)
                return (bits << 1) ^ UInt128(bitPattern: value >> 127)
            }
        )
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension UInt128 {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let magnitude = domain.numericMagnitude else {
            return defaultGenerator
        }
        return boundedWideBits(maximumGeneratedValue: UInt64(magnitude))
    }
}

#if canImport(CoreGraphics)
    extension CGFloat {
        static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
            guard let magnitude = domain.numericMagnitude else {
                return defaultGenerator
            }
            let bound = Double(magnitude)
            return Gen.isomorphed(
                Gen.chooseDerived(in: -bound ... bound, scaling: .linear),
                forward: { CGFloat($0) },
                backward: { Double($0) }
            ).gen.wrapped(isReflective: true)
        }
    }
#endif

// MARK: - Helpers

/// Prebuilds exact size-bounded integer ranges rather than using the general linear scaler's extra endpoint allowance. Equal ranges share a completed leaf, and the full domain never enters this path.
private func boundedInteger<Value: FixedWidthInteger & BitPatternConvertible>(
    in range: ClosedRange<Value>
) -> ReflectiveGenerator<Value> {
    sizeIndexedLayers(
        key: { size in
            let lower = Value((Double(Int(range.lowerBound)) * Double(size) / 100).rounded())
            let upper = Value((Double(Int(range.upperBound)) * Double(size) / 100).rounded())
            return lower ... upper
        },
        build: { bounds in Gen.chooseDerived(in: bounds).wrapped(isReflective: true) }
    )
}

/// Generates small 128-bit samples while keeping both halves open to reflection.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func boundedWideBits(
    maximumGeneratedValue: UInt64
) -> ReflectiveGenerator<UInt128> {
    sizeIndexedLayers(
        key: { size in
            UInt64((Double(maximumGeneratedValue) * Double(size) / 100).rounded())
        },
        build: { maximumValue in
            Gen.zip(
                Gen.chooseDerived(in: UInt64(0) ... 0),
                Gen.chooseDerived(in: UInt64(0) ... maximumValue)
            ).wrapped(isReflective: true).mapped(
                forward: { high, low in
                    UInt128(high) << 64 | UInt128(low)
                },
                backward: { value in
                    (
                        UInt64(truncatingIfNeeded: value >> 64),
                        UInt64(truncatingIfNeeded: value)
                    )
                }
            )
        }
    )
}
