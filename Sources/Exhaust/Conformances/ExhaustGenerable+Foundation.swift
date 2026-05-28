import ExhaustCore
import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension String: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<String>.string().gen.erase()
    }
}

extension Character: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<Character>.character().gen.erase()
    }
}

extension UUID: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<UUID>.uuid().gen.erase()
    }
}

extension URL: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<URL>.url().gen.erase()
    }
}

extension Date: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<Date>.date(
            between: Date.distantPast ... Date.distantFuture,
            interval: .minutes(1)
        ).gen.erase()
    }
}

extension Data: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<Data>.data().gen.erase()
    }
}

#if canImport(CoreGraphics)
    extension CGFloat: ExhaustGenerable {
        package static var defaultGenerator: AnyGenerator {
            ReflectiveGenerator<CGFloat>.cgfloat().gen.erase()
        }
    }
#endif

extension Decimal: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        ReflectiveGenerator<Decimal>.decimal(
            in: Decimal(Int64.min) ... Decimal(Int64.max),
            precision: 2
        ).gen.erase()
    }
}
