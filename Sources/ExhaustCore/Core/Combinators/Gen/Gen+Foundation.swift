//
//  Gen+Foundation.swift
//  Exhaust
//
//  Canonical implementations for the Foundation-type generators. The public
//  `ReflectiveGenerator.*` factories in the `Exhaust` module and the
//  `ExhaustGenerable.defaultGenerator` conformances both forward here, so the
//  per-sample transform closures are authored — and therefore compiled
//  optimized — inside the prebuilt `ExhaustCore` binary rather than in the
//  consumer's debug build.
//

import Foundation

// MARK: - UUID

package extension Gen {
    /// Generates valid UUID v4 values from two `UInt64` halves.
    ///
    /// The two `chooseBits` ranges carry exactly 122 random bits (60 + 62). The mapping is bijective within the generated v4 domain; reflection also accepts other `Foundation.UUID` values by stripping their version and variant bits, so replay canonicalizes those values to v4.
    static func uuid() -> ReflectiveGenerator<UUID> {
        Gen.zip(
            Gen.chooseBits(in: 0 ... 0x0FFF_FFFF_FFFF_FFFF),
            Gen.chooseBits(in: 0 ... 0x3FFF_FFFF_FFFF_FFFF)
        ).wrapped.mapped(
            forward: { uuidFromHalves($0, $1) },
            backward: { uuidToHalves($0) }
        )
    }
}

// MARK: - UUID v4 Bit Layout

//
// Bytes 0–7 (high UInt64, big-endian):
//   bits 63–16: 48 random bits (bytes 0–5)
//   bits 15–12: version nibble = 0x4
//   bits 11–0:  12 random bits (byte 6 low nibble + byte 7)
//   Total: 60 random bits
//
// Bytes 8–15 (low UInt64, big-endian):
//   bits 63–62: variant = 0b10
//   bits 61–0:  62 random bits
//   Total: 62 random bits
//
// Generators produce only the random bits; fixed bits are inserted/stripped in the forward/backward functions below.

private func uuidFromHalves(_ high60: UInt64, _ low62: UInt64) -> UUID {
    let highU64 = ((high60 >> 12) << 16) | (0x4 << 12) | (high60 & 0xFFF)
    let lowU64 = 0x8000_0000_0000_0000 | low62

    var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &bytes) { buf in
        buf.storeBytes(of: highU64.bigEndian, as: UInt64.self)
        buf.storeBytes(of: lowU64.bigEndian, toByteOffset: 8, as: UInt64.self)
    }
    return UUID(uuid: bytes)
}

private func uuidToHalves(_ uuid: UUID) -> (UInt64, UInt64) {
    withUnsafeBytes(of: uuid.uuid) { buf in
        let rawHigh = UInt64(bigEndian: buf.loadUnaligned(as: UInt64.self))
        let rawLow = UInt64(bigEndian: buf.loadUnaligned(fromByteOffset: 8, as: UInt64.self))

        let high60 = ((rawHigh >> 16) << 12) | (rawHigh & 0xFFF)
        let low62 = rawLow & 0x3FFF_FFFF_FFFF_FFFF

        return (high60, low62)
    }
}

// MARK: - URL

package extension Gen {
    /// Generates structurally-random URLs that always parse.
    ///
    /// Forward-only: a `URL` cannot be decomposed back into its generator inputs, so reflection is unsupported. Reduction still works through the underlying choice sequence.
    static func url() -> ReflectiveGenerator<URL> {
        let scheme: Generator<String> = Gen.pick(choices: [
            (1, Gen.just("http")),
            (1, Gen.just("https")),
        ])

        let label = alphanumericString(length: 3 ... 10)
        let host = Gen.arrayOf(label, within: 2 ... 3, scaling: .constant)
            .map { $0.joined(separator: ".") }

        let pathSegment = alphanumericString(length: 1 ... 8)
        let path = Gen.arrayOf(pathSegment, within: 0 ... 3, scaling: .constant)
            .map { segments in
                segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
            }

        let queryKey = alphanumericString(length: 2 ... 6)
        let queryValue = alphanumericString(length: 1 ... 8)
        let queryPair = Gen.zip(queryKey, queryValue)
            .map { "\($0)=\($1)" }
        let query = Gen.arrayOf(queryPair, within: 0 ... 2, scaling: .constant)
            .map { pairs in
                pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
            }

        return Gen.liftF(.transform(
            kind: .map(
                forward: { tuple in
                    let (scheme, host, path, query) = tuple as! (String, String, String, String)
                    return URL(string: "\(scheme)://\(host)\(path)\(query)")!
                },
                backward: nil,
                inputType: (String, String, String, String).self,
                outputType: URL.self
            ),
            inner: Gen.zip(scheme, host, path, query).erase()
        )).wrapped
    }
}

/// Generates a lowercase alphanumeric string with length in the given range.
private func alphanumericString(
    length: ClosedRange<UInt64>
) -> Generator<String> {
    let chars = Gen.choose(in: UInt8(0) ... 35)
        .map { value -> Character in
            if value < 26 {
                Character(UnicodeScalar(UInt8(ascii: "a") + value))
            } else {
                Character(UnicodeScalar(UInt8(ascii: "0") + value - 26))
            }
        }
    return Gen.arrayOf(chars, within: length, scaling: .constant)
        .map { String($0) }
}

// MARK: - Date

package extension Gen {
    /// Generates dates within the given range, quantized to integral multiples of `interval` relative to the lower bound.
    ///
    /// `timeZone` selects which zone's DST transitions problematic-value analysis includes; it does not change the generated grid. The UTC default has no DST transitions, keeping screening rows identical across machines. Reflection rounds off-grid dates down to the nearest step rather than rejecting them.
    static func date(
        between range: ClosedRange<Date>,
        interval: DateStride,
        timeZone: TimeZone = TimeZone(identifier: "UTC")!
    ) -> ReflectiveGenerator<Date> {
        let lowerSeconds = Int64(range.lowerBound.timeIntervalSinceReferenceDate)
        let upperSeconds = Int64(range.upperBound.timeIntervalSinceReferenceDate)
        let intervalSeconds = Int64(abs(interval.fixedSeconds))

        precondition(intervalSeconds > 0, "Interval must be non-zero")
        precondition(
            intervalSeconds <= upperSeconds - lowerSeconds,
            "Interval must not exceed the date range"
        )

        let numSteps = (upperSeconds - lowerSeconds) / intervalSeconds

        return Generator<Int64>.impure(
            operation: .chooseBits(
                min: Int64(0).bitPattern64,
                max: numSteps.bitPattern64,
                tag: .date,
                isRangeExplicit: true,
                typeTagPayload: .date(
                    lowerSeconds: lowerSeconds,
                    intervalSeconds: intervalSeconds,
                    timeZoneID: timeZone.identifier
                )
            )
        ) { try .pure(Int64(bitPattern64: chooseBitsBitPattern($0))) }
            .wrapped.mapped(
                forward: { step in
                    Date(timeIntervalSinceReferenceDate: Double(lowerSeconds + step * intervalSeconds))
                },
                backward: { date in
                    let offset = date.timeIntervalSinceReferenceDate - Double(lowerSeconds)
                    return Int64(floor(offset / Double(intervalSeconds)))
                }
            )
    }
}

// MARK: - Decimal

package extension Gen {
    /// Generates `Decimal` values within `range`, quantized to `precision` decimal places.
    ///
    /// Values are represented internally as `Int64` steps scaled by `10^precision`; the backward map snaps off-precision values to the nearest step and clamps out-of-range values to the nearest bound.
    static func decimal(
        in range: ClosedRange<Decimal>,
        precision: UInt8
    ) -> ReflectiveGenerator<Decimal> {
        let multiplier = pow(10, Int(precision)) as Decimal
        let lowerScaled = range.lowerBound * multiplier
        let upperScaled = range.upperBound * multiplier
        let int64Min = Decimal(Int64.min)
        let int64Max = Decimal(Int64.max)

        precondition(
            lowerScaled >= int64Min && lowerScaled <= int64Max
                && upperScaled >= int64Min && upperScaled <= int64Max,
            "Decimal range scaled by 10^\(precision) must fit within Int64 (got \(lowerScaled) ... \(upperScaled))"
        )

        let lowerStep = Int64(truncating: lowerScaled as NSDecimalNumber)
        let upperStep = Int64(truncating: upperScaled as NSDecimalNumber)

        precondition(
            lowerStep <= upperStep,
            "Lower bound must not exceed upper bound after scaling"
        )

        return Gen.choose(in: lowerStep ... upperStep).wrapped
            .mapped(
                forward: { step in
                    Decimal(step) / multiplier
                },
                backward: { target in
                    let scaled = Int64(truncating: (target * multiplier) as NSDecimalNumber)
                    return min(max(scaled, lowerStep), upperStep)
                }
            )
    }
}

// MARK: - Character and String

package extension Gen {
    /// Generates a Unicode character from all valid scalars except illegals and the Private Use Areas.
    static func character() -> ReflectiveGenerator<Character> {
        characterGenerator(from: defaultScalarRangeSet).wrapped
    }

    /// Generates a character drawn uniformly from `characterSet`.
    static func character(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil
    ) -> ReflectiveGenerator<Character> {
        let bottom = resolveSimplest(simplest, in: characterSet)
        return characterGenerator(from: characterSet.scalarRangeSet(bottomCodepoint: bottom)).wrapped
    }

    /// Generates a character drawn from the union of two or more character sets.
    static func character(from first: CharacterSet, _ rest: CharacterSet...) -> ReflectiveGenerator<Character> {
        let combined = rest.reduce(first) { $0.union($1) }
        return character(from: combined)
    }

    /// Generates a Unicode string with size-scaled or fixed length, drawing from all valid scalars except illegals and the Private Use Areas.
    static func string(
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        stringGenerator(from: defaultScalarRangeSet, length: length, scaling: scaling)
    }

    /// Generates a printable ASCII string (U+0020–U+007E) with size-scaled or fixed length.
    static func asciiString(
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        stringGenerator(from: asciiScalarRangeSet, length: length, scaling: scaling)
    }

    /// Generates a string whose characters are drawn from `characterSet`.
    ///
    /// `simplest` is the scalar each character reduces toward; it defaults to space when in the set, otherwise the set's natural lower bound.
    static func string(
        from characterSet: CharacterSet,
        simplest: Unicode.Scalar? = nil,
        length: ClosedRange<UInt64>? = nil,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<String> {
        let bottom = resolveSimplest(simplest, in: characterSet)
        return stringGenerator(
            from: characterSet.scalarRangeSet(bottomCodepoint: bottom),
            length: length,
            scaling: scaling
        )
    }
}

// MARK: - Simplest Character Resolution

/// Resolves the bottom codepoint for a character set.
///
/// - If the caller provides an explicit `simplest`, validates it is in the set and returns it.
/// - If nil, returns space if the set contains it, otherwise nil (the set's natural lower bound becomes index 0).
private func resolveSimplest(
    _ explicit: Unicode.Scalar?,
    in characterSet: CharacterSet
) -> Unicode.Scalar? {
    if let explicit {
        precondition(
            characterSet.contains(explicit),
            "simplest scalar U+\(String(explicit.value, radix: 16, uppercase: true)) is not in the CharacterSet"
        )
        return explicit
    }
    if characterSet.contains(" ") {
        return " "
    }
    return nil
}

// MARK: - ScalarRangeSet-based generators (no CharacterSet reconstruction)

/// Builds a character generator directly from a pre-computed ``ScalarRangeSet``.
private func characterGenerator(from srs: ScalarRangeSet) -> Generator<Character> {
    let operation = ReflectiveOperation.chooseBits(
        min: 0,
        max: UInt64(srs.scalarCount - 1),
        tag: .character,
        isRangeExplicit: true,
        typeTagPayload: .character(problematicIndices: srs.problematicIndices)
    )
    let innerGen = Generator<Character>.impure(operation: operation) { result in
        try .pure(Character(srs.scalar(at: Int(chooseBitsBitPattern(result)))))
    }
    return Gen.contramap(
        { (char: Character) throws -> UInt32 in
            guard let scalar = char.unicodeScalars.first else {
                throw ReflectionError.couldNotReflectOnSequenceElement(
                    "Character has no scalars"
                )
            }
            return UInt32(srs.index(of: scalar))
        },
        innerGen
    )
}

/// Builds a string generator directly from a pre-computed ``ScalarRangeSet``.
///
/// String <-> [Character] is not bijective when the CharacterSet includes combining marks.
/// The generator produces single-scalar characters, but Array(string) splits by grapheme clusters — so if "e" followed by U+0301 (combining accent) were generated as two characters, the String merges them into "é", and Array(...) returns one Character instead of two. We use `unicodeScalars.map` in the backward direction to preserve the original scalar count.
private func stringGenerator(
    from srs: ScalarRangeSet,
    length: ClosedRange<UInt64>? = nil,
    scaling: SizeScaling<UInt64> = .linear
) -> ReflectiveGenerator<String> {
    let charGen = characterGenerator(from: srs)
    if let length {
        return Gen.arrayOf(charGen, within: length, scaling: scaling).wrapped
            .mapped(
                forward: { String($0) },
                backward: { $0.unicodeScalars.map { Character($0) } }
            )
    }
    return Gen.arrayOf(charGen).wrapped
        .mapped(
            forward: { String($0) },
            backward: { $0.unicodeScalars.map { Character($0) } }
        )
}

// MARK: - Pre-computed ScalarRangeSets

/// All assigned Unicode scalars minus illegals and Private Use Areas. Reduces toward space (U+0020).
private let defaultScalarRangeSet: ScalarRangeSet = CharacterSet.illegalCharacters.inverted
    .removingPrivateUseAreas()
    .scalarRangeSet(bottomCodepoint: " ")

/// Printable ASCII (U+0020–U+007E). Space is naturally at index 0; no bottom codepoint needed.
private let asciiScalarRangeSet: ScalarRangeSet =
    CharacterSet(charactersIn: Unicode.Scalar(0x0020)! ... Unicode.Scalar(0x007E)!).scalarRangeSet()

// MARK: - Data

package extension Gen {
    /// Generates `Data` with size-scaled length, each byte uniform in 0...255.
    static func data() -> ReflectiveGenerator<Data> {
        Gen.arrayOf(Gen.choose(in: UInt8.min ... UInt8.max)).wrapped
            .mapped(
                forward: { Data($0) },
                backward: { Array($0) }
            )
    }

    /// Generates `Data` with length in `range`, each byte uniform in 0...255.
    static func data(
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Data> {
        Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            within: range,
            scaling: scaling
        ).wrapped.mapped(
            forward: { Data($0) },
            backward: { Array($0) }
        )
    }

    /// Generates `Data` of exactly `length` bytes, each byte uniform in 0...255.
    static func data(
        length: UInt64
    ) -> ReflectiveGenerator<Data> {
        Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            exactly: length
        ).wrapped.mapped(
            forward: { Data($0) },
            backward: { Array($0) }
        )
    }

    /// Generates `Data` with `prefix` followed by a size-scaled random suffix.
    static func data(
        prefix: [UInt8]
    ) -> ReflectiveGenerator<Data> {
        let generator = Gen.arrayOf(Gen.choose(in: UInt8.min ... UInt8.max)).wrapped
            .mapped(
                forward: { Data(prefix + $0) },
                backward: { Array($0.dropFirst(prefix.count)) }
            )
        return validatingDataPrefix(generator, prefix: prefix)
    }

    /// Generates `Data` with `prefix` followed by a random suffix with length in `range`.
    static func data(
        prefix: [UInt8],
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Data> {
        let generator = Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            within: range,
            scaling: scaling
        ).wrapped.mapped(
            forward: { Data(prefix + $0) },
            backward: { Array($0.dropFirst(prefix.count)) }
        )
        return validatingDataPrefix(generator, prefix: prefix)
    }

    /// Generates `Data` with `prefix` followed by exactly `length` random bytes.
    static func data(
        prefix: [UInt8],
        length: UInt64
    ) -> ReflectiveGenerator<Data> {
        let generator = Gen.arrayOf(
            Gen.choose(in: UInt8.min ... UInt8.max),
            exactly: length
        ).wrapped.mapped(
            forward: { Data(prefix + $0) },
            backward: { Array($0.dropFirst(prefix.count)) }
        )
        return validatingDataPrefix(generator, prefix: prefix)
    }
}

private func validatingDataPrefix(
    _ generator: ReflectiveGenerator<Data>,
    prefix: [UInt8]
) -> ReflectiveGenerator<Data> {
    Gen.comap(
        { (data: Data) -> Data? in data.starts(with: prefix) ? data : nil },
        generator.gen
    ).wrapped
}

// MARK: - CharacterSet Extensions

private extension CharacterSet {
    /// Returns a copy with the three Unicode Private Use Areas removed.
    ///
    /// - BMP PUA: U+E000–U+F8FF (6,400 code points)
    /// - Supplementary PUA-A (Plane 15): U+F0000–U+FFFFD (65,534 code points)
    /// - Supplementary PUA-B (Plane 16): U+100000–U+10FFFD (65,534 code points)
    func removingPrivateUseAreas() -> CharacterSet {
        var result = self
        result.remove(charactersIn: Unicode.Scalar(0xE000)! ... Unicode.Scalar(0xF8FF)!)
        result.remove(charactersIn: Unicode.Scalar(0xF0000)! ... Unicode.Scalar(0xFFFFD)!)
        result.remove(charactersIn: Unicode.Scalar(0x100000)! ... Unicode.Scalar(0x10FFFD)!)
        return result
    }
}
