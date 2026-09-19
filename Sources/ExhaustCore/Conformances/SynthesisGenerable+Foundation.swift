import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension String: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.string().gen.erase()
    }
}

extension Character: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.character().gen.erase()
    }
}

extension UUID: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.uuid().gen.erase()
    }
}

extension URL: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.url().gen.erase()
    }
}

extension Date: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.date(
            between: Date.distantPast ... Date.distantFuture,
            interval: .seconds(60)
        ).gen.erase()
    }
}

extension Data: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.data().gen.erase()
    }
}

#if canImport(CoreGraphics)
    extension CGFloat: SynthesisGenerable {
        package static var defaultGenerator: AnyGenerator {
            Gen.choose(
                in: nil as ClosedRange<Double>?,
                type: Double.self,
                isRangeExplicit: false,
                scaling: Double.defaultScaling.erased
            ).map { CGFloat($0) }.erase()
        }
    }
#endif

extension Decimal: SynthesisGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.decimal(
            in: Decimal(Int64.min) / 100 ... Decimal(Int64.max) / 100,
            precision: 2
        ).gen.erase()
    }
}
