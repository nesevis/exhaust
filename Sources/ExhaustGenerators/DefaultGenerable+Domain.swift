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
        guard let numeric = domain.numeric else {
            return defaultGenerator
        }
        let range = Self(clamping: -numeric.magnitude) ... Self(clamping: numeric.magnitude)
        return Gen.chooseDerived(
            in: range,
            scaling: numeric.scaling.resolved()
        ).wrapped(isReflective: true)
    }
}

extension DefaultGenerable where Self: BinaryFloatingPoint & BitPatternConvertible {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let numeric = domain.numeric else {
            return defaultGenerator
        }
        let bound = Self(numeric.magnitude)
        return Gen.chooseDerived(
            in: -bound ... bound,
            scaling: numeric.scaling.resolved()
        ).wrapped(isReflective: true)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension Int128 {
    static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
        guard let numeric = domain.numeric else {
            return defaultGenerator
        }
        let bits = boundedWideBits(
            maximumGeneratedValue: UInt64(numeric.magnitude) * 2,
            scaling: numeric.scaling.resolved()
        )
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
        guard let numeric = domain.numeric else {
            return defaultGenerator
        }
        return boundedWideBits(
            maximumGeneratedValue: UInt64(numeric.magnitude),
            scaling: numeric.scaling.resolved()
        )
    }
}

#if canImport(CoreGraphics)
    extension CGFloat {
        static func defaultGenerator(domain: ExhaustableDomain) -> ReflectiveGenerator<Self> {
            guard let numeric = domain.numeric else {
                return defaultGenerator
            }
            let bound = Double(numeric.magnitude)
            return Gen.isomorphed(
                Gen.chooseDerived(
                    in: -bound ... bound,
                    scaling: numeric.scaling.resolved()
                ),
                forward: { CGFloat($0) },
                backward: { Double($0) }
            ).gen.wrapped(isReflective: true)
        }
    }
#endif

// MARK: - Helpers

/// Generates bounded 128-bit samples while keeping both halves open to reflection.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
private func boundedWideBits(
    maximumGeneratedValue: UInt64,
    scaling: SizeScaling<UInt64>
) -> ReflectiveGenerator<UInt128> {
    Gen.zip(
        Gen.chooseDerived(in: UInt64(0) ... 0),
        Gen.chooseDerived(
            in: UInt64(0) ... maximumGeneratedValue,
            scaling: scaling
        )
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

private extension ExhaustableSizeScaling {
    /// Bridges the app-safe domain policy to the generator runtime's payload-specific scaling type.
    func resolved<Bound: Sendable>() -> SizeScaling<Bound> {
        switch self {
            case .constant:
                .constant
            case .linear:
                .linear
            case .exponential:
                .exponential
        }
    }
}
