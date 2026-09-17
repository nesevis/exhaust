#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Exhaustable
import ExhaustCore
import Foundation

/// Supplies Exhaust's internal catalogue of standard-library and Foundation generators to the derivation resolver.
///
/// This is not a user customization point. Annotated types expose their derived generator through ``__Exhaustable/Conformance/defaultGenerator``; other payload generators are supplied explicitly through `overriding:`. Witness properties stay internal as well, so the catalogue does not add public factory members to standard-library types.
protocol DefaultGenerable {
    /// The generator used for this type when no other is named.
    static var defaultGenerator: ReflectiveGenerator<Self> { get }

    /// Applies numeric domain presets while leaving other built-in defaults unchanged.
    static func defaultGenerator(stateSpace: GeneratorStateSpace) -> ReflectiveGenerator<Self>
}

// MARK: - Standard Library

extension Bool: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Bool> {
        .bool()
    }
}

extension Int: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int> {
        .int()
    }
}

extension Int8: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int8> {
        .int8()
    }
}

extension Int16: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int16> {
        .int16()
    }
}

extension Int32: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int32> {
        .int32()
    }
}

extension Int64: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int64> {
        .int64()
    }
}

extension UInt: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt> {
        .uint()
    }
}

extension UInt8: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt8> {
        .uint8()
    }
}

extension UInt16: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt16> {
        .uint16()
    }
}

extension UInt32: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt32> {
        .uint32()
    }
}

extension UInt64: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt64> {
        .uint64()
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension Int128: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Int128> {
        .int128()
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
extension UInt128: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UInt128> {
        .uint128()
    }
}

extension Double: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Double> {
        .double()
    }
}

extension Float: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Float> {
        .float()
    }
}

#if arch(arm64) || arch(arm64_32)
    @available(macOS 11, iOS 14, tvOS 14, watchOS 7, *)
    extension Float16: DefaultGenerable {
        static var defaultGenerator: ReflectiveGenerator<Float16> {
            .float16()
        }
    }
#endif

extension String: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<String> {
        .string()
    }
}

extension Character: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Character> {
        .character()
    }
}

// MARK: - Foundation

extension Date: DefaultGenerable {
    /// Any date at one-minute resolution, matching the synthesizer's default for `Date` fields.
    static var defaultGenerator: ReflectiveGenerator<Date> {
        .date(between: Date.distantPast ... Date.distantFuture, interval: .seconds(60))
    }
}

extension UUID: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<UUID> {
        .uuid()
    }
}

extension URL: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<URL> {
        .url()
    }
}

extension Data: DefaultGenerable {
    static var defaultGenerator: ReflectiveGenerator<Data> {
        .data()
    }
}

extension Decimal: DefaultGenerable {
    /// Two decimal places over the range a 64-bit count of minor units can express, matching the synthesizer's default for `Decimal` fields.
    static var defaultGenerator: ReflectiveGenerator<Decimal> {
        .decimal(in: Decimal(Int64.min) / 100 ... Decimal(Int64.max) / 100, precision: 2)
    }
}

#if canImport(CoreGraphics)
    extension CGFloat: DefaultGenerable {
        static var defaultGenerator: ReflectiveGenerator<CGFloat> {
            .cgfloat()
        }
    }
#endif
