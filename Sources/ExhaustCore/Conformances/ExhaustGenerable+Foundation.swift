import Foundation

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

extension String: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let srs = CharacterSet.illegalCharacters.inverted
            .removingPrivateUseAreas()
            .scalarRangeSet(bottomCodepoint: " ")
        let charGen = characterGeneratorFromScalarRangeSet(srs)
        return Gen.arrayOf(charGen)
            .map { String($0) }
            .erase()
    }
}

extension Character: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let srs = CharacterSet.illegalCharacters.inverted
            .removingPrivateUseAreas()
            .scalarRangeSet(bottomCodepoint: " ")
        return characterGeneratorFromScalarRangeSet(srs).erase()
    }
}

extension UUID: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.zip(
            Gen.chooseBits(in: 0 ... 0x0FFF_FFFF_FFFF_FFFF),
            Gen.chooseBits(in: 0 ... 0x3FFF_FFFF_FFFF_FFFF)
        ).map { high60, low62 -> UUID in
            let highU64 = ((high60 >> 12) << 16) | (0x4 << 12) | (high60 & 0xFFF)
            let lowU64: UInt64 = 0x8000_0000_0000_0000 | low62
            var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            withUnsafeMutableBytes(of: &bytes) { buffer in
                buffer.storeBytes(of: highU64.bigEndian, as: UInt64.self)
                buffer.storeBytes(of: lowU64.bigEndian, toByteOffset: 8, as: UInt64.self)
            }
            return UUID(uuid: bytes)
        }.erase()
    }
}

extension URL: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let alphaChars = Gen.choose(in: UInt8(0) ... 35)
            .map { value -> Character in
                if value < 26 {
                    Character(UnicodeScalar(UInt8(ascii: "a") + value))
                } else {
                    Character(UnicodeScalar(UInt8(ascii: "0") + value - 26))
                }
            }
        func alphaString(length: ClosedRange<UInt64>) -> Generator<String> {
            Gen.arrayOf(alphaChars, within: length, scaling: .constant)
                .map { String($0) }
        }

        let scheme: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("http")),
            (1, Gen.just("https")),
        ])
        let host = Gen.arrayOf(alphaString(length: 3 ... 10), within: 2 ... 3, scaling: .constant)
            .map { $0.joined(separator: ".") }
        let path = Gen.arrayOf(alphaString(length: 1 ... 8), within: 0 ... 3, scaling: .constant)
            .map { $0.isEmpty ? "" : "/" + $0.joined(separator: "/") }
        let queryPair = Gen.zip(alphaString(length: 2 ... 6), alphaString(length: 1 ... 8))
            .map { "\($0)=\($1)" }
        let query = Gen.arrayOf(queryPair, within: 0 ... 2, scaling: .constant)
            .map { $0.isEmpty ? "" : "?" + $0.joined(separator: "&") }

        return Gen.zip(scheme, host, path, query)
            .map { scheme, host, path, query in
                URL(string: "\(scheme)://\(host)\(path)\(query)")!
            }.erase()
    }
}

extension Date: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let lowerSeconds = Int64(Date.distantPast.timeIntervalSinceReferenceDate)
        let upperSeconds = Int64(Date.distantFuture.timeIntervalSinceReferenceDate)
        let intervalSeconds: Int64 = 60
        let numSteps = (upperSeconds - lowerSeconds) / intervalSeconds

        return Generator<Int64>.impure(
            operation: .chooseBits(
                min: Int64(0).bitPattern64,
                max: numSteps.bitPattern64,
                tag: .date(
                    lowerSeconds: lowerSeconds,
                    intervalSeconds: intervalSeconds,
                    timeZoneID: TimeZone.current.identifier
                ),
                isRangeExplicit: true
            )
        ) { .pure(Int64(bitPattern64: ($0 as! any BitPatternConvertible).bitPattern64)) }
            .map { step in
                Date(timeIntervalSinceReferenceDate: TimeInterval(lowerSeconds + step * intervalSeconds))
            }.erase()
    }
}

extension Data: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        Gen.arrayOf(Gen.choose(in: UInt8.min ... UInt8.max))
            .map { Data($0) }
            .erase()
    }
}

#if canImport(CoreGraphics)
    extension CGFloat: ExhaustGenerable {
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

extension Decimal: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let multiplier = pow(10, 2) as Decimal
        let lowerStep = Int64(truncating: (Decimal(Int64.min) * multiplier) as NSDecimalNumber)
        let upperStep = Int64(truncating: (Decimal(Int64.max) * multiplier) as NSDecimalNumber)

        return Gen.choose(in: lowerStep ... upperStep)
            .map { step in Decimal(step) / multiplier }
            .erase()
    }
}

// MARK: - Helpers

private func characterGeneratorFromScalarRangeSet(_ srs: ScalarRangeSet) -> Generator<Character> {
    let operation = ReflectiveOperation.chooseBits(
        min: 0,
        max: UInt64(srs.scalarCount - 1),
        tag: .character(boundaryIndices: srs.boundaryIndices),
        isRangeExplicit: true
    )
    return Generator<Character>.impure(operation: operation) { result in
        guard let convertible = result as? any BitPatternConvertible else {
            throw GeneratorError.typeMismatch(
                expected: "any BitPatternConvertible",
                actual: String(describing: Swift.type(of: result))
            )
        }
        return .pure(Character(srs.scalar(at: Int(convertible.bitPattern64))))
    }
}

private extension CharacterSet {
    func removingPrivateUseAreas() -> CharacterSet {
        var result = self
        result.remove(charactersIn: Unicode.Scalar(0xE000)! ... Unicode.Scalar(0xF8FF)!)
        result.remove(charactersIn: Unicode.Scalar(0xF0000)! ... Unicode.Scalar(0xFFFFD)!)
        result.remove(charactersIn: Unicode.Scalar(0x100000)! ... Unicode.Scalar(0x10FFFD)!)
        return result
    }
}
