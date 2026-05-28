// MARK: - Boolean

extension Bool: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt8(0) ... 1, scaling: .constant)
            .map { $0 == 1 }
            .erase()
    }
}

// MARK: - Signed Integers

extension Int: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: Int.min ... Int.max, scaling: Int.defaultScaling).erase()
    }
}

extension Int8: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: Int8.min ... Int8.max, scaling: Int8.defaultScaling).erase()
    }
}

extension Int16: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: Int16.min ... Int16.max, scaling: Int16.defaultScaling).erase()
    }
}

extension Int32: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: Int32.min ... Int32.max, scaling: Int32.defaultScaling).erase()
    }
}

extension Int64: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: Int64.min ... Int64.max, scaling: Int64.defaultScaling).erase()
    }
}

// MARK: - Unsigned Integers

extension UInt: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt.min ... UInt.max, scaling: UInt.defaultScaling).erase()
    }
}

extension UInt8: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt8.min ... UInt8.max, scaling: UInt8.defaultScaling).erase()
    }
}

extension UInt16: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt16.min ... UInt16.max, scaling: UInt16.defaultScaling).erase()
    }
}

extension UInt32: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt32.min ... UInt32.max, scaling: UInt32.defaultScaling).erase()
    }
}

extension UInt64: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(in: UInt64.min ... UInt64.max, scaling: UInt64.defaultScaling).erase()
    }
}

// MARK: - Floating Point

extension Double: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(
            in: nil as ClosedRange<Double>?,
            type: Double.self,
            isRangeExplicit: false,
            scaling: Double.defaultScaling.erased
        ).erase()
    }
}

extension Float: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.choose(
            in: nil as ClosedRange<Float>?,
            type: Float.self,
            isRangeExplicit: false,
            scaling: Float.defaultScaling.erased
        ).erase()
    }
}
