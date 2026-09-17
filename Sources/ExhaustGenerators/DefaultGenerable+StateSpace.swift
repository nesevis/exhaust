#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Exhaustable
import ExhaustCore

extension DefaultGenerable {
    static func defaultGenerator(stateSpace _: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
        defaultGenerator
    }
}

extension DefaultGenerable where Self: FixedWidthInteger & BitPatternConvertible {
    static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
        guard let magnitude = stateSpace.numericMagnitude else {
            return defaultGenerator
        }
        let range = Self(clamping: -magnitude) ... Self(clamping: magnitude)
        return boundedInteger(in: range)
    }
}

extension DefaultGenerable where Self: BinaryFloatingPoint & BitPatternConvertible {
    static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
        guard let magnitude = stateSpace.numericMagnitude else {
            return defaultGenerator
        }
        let bound = Self(magnitude)
        return Gen.choose(in: -bound ... bound, scaling: .linear).wrapped(isReflective: true)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension Int128 {
    static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
        guard let magnitude = stateSpace.numericMagnitude else {
            return defaultGenerator
        }
        return boundedWideInteger(Self.self, magnitude: magnitude)
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension UInt128 {
    static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
        guard let magnitude = stateSpace.numericMagnitude else {
            return defaultGenerator
        }
        return boundedWideInteger(Self.self, magnitude: magnitude)
    }
}

#if canImport(CoreGraphics)
    extension CGFloat {
        static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self> {
            guard let magnitude = stateSpace.numericMagnitude else {
                return defaultGenerator
            }
            let bound = CGFloat(magnitude)
            return .cgfloat(in: -bound ... bound, scaling: .linear)
        }
    }
#endif

// MARK: - Helpers

/// Prebuilds exact size-bounded integer ranges rather than using the general linear scaler's extra endpoint allowance. Equal ranges share a completed leaf, and the full state space never enters this path.
private func boundedInteger<Value: FixedWidthInteger & BitPatternConvertible>(
    in range: ClosedRange<Value>
) -> ReflectiveGenerator<Value> {
    sizeIndexedLayers(
        key: { size in
            let lower = Value((Double(Int(range.lowerBound)) * Double(size) / 100).rounded())
            let upper = Value((Double(Int(range.upperBound)) * Double(size) / 100).rounded())
            return lower ... upper
        },
        build: { bounds in Gen.choose(in: bounds).wrapped(isReflective: true) }
    )
}

/// Uses an exactly invertible machine-integer representation for bounded 128-bit values; the full state space still uses the original two-half generator.
private func boundedWideInteger<Value: FixedWidthInteger>(
    _: Value.Type,
    magnitude: Int
) -> ReflectiveGenerator<Value> {
    let lowerBound = Value.isSigned ? -magnitude : 0
    let inner = boundedInteger(in: lowerBound ... magnitude)
    return Gen.isomorphed(
        inner.gen,
        forward: { Value($0) },
        backward: { value in
            guard let integer = Int(exactly: value) else {
                throw ReflectionError.inputWasOutOfGeneratorRange(
                    String(describing: value),
                    range: "\(lowerBound)...\(magnitude)"
                )
            }
            return integer
        }
    ).gen.wrapped(isReflective: true)
}
