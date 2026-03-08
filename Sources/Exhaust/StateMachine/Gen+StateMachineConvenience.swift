// Convenience forwarding methods on Gen for use in @Command attributes.
//
// ReflectiveGenerator factory methods like .int(in:), .string(), etc. are
// defined as static methods on ReflectiveGenerator<T>. These forwarders let
// users write Gen.int(in: 0...99) in @Command attributes where implicit
// member syntax is not available.
import ExhaustCore

public extension Gen {
    /// Generates arbitrary integers within the given range.
    @inlinable
    static func int(in range: ClosedRange<Int>? = nil) -> ReflectiveGenerator<Int> {
        ReflectiveGenerator<Int>.int(in: range)
    }

    /// Generates arbitrary unsigned integers within the given range.
    @inlinable
    static func uint(in range: ClosedRange<UInt>? = nil) -> ReflectiveGenerator<UInt> {
        ReflectiveGenerator<UInt>.uint(in: range)
    }

    /// Generates arbitrary strings.
    @inlinable
    static func string() -> ReflectiveGenerator<String> {
        ReflectiveGenerator<String>.string()
    }

    /// Generates arbitrary ASCII strings.
    @inlinable
    static func asciiString() -> ReflectiveGenerator<String> {
        ReflectiveGenerator<String>.asciiString()
    }

    /// Generates arbitrary booleans.
    @inlinable
    static func bool() -> ReflectiveGenerator<Bool> {
        ReflectiveGenerator<Bool>.bool()
    }

    /// Generates arbitrary doubles within the given range.
    @inlinable
    static func double(in range: ClosedRange<Double>? = nil) -> ReflectiveGenerator<Double> {
        ReflectiveGenerator<Double>.double(in: range)
    }

    /// Generates arbitrary floats within the given range.
    @inlinable
    static func float(in range: ClosedRange<Float>? = nil) -> ReflectiveGenerator<Float> {
        ReflectiveGenerator<Float>.float(in: range)
    }
}
