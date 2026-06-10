/// Identifies a specific failing run for deterministic reproduction, accepting either a raw `UInt64` or an encoded string.
///
/// Three wire formats:
/// - **Bare seed**: Crockford Base32 encoded `UInt64` (for example, `"3RT5GH8KM2"`). Replays the full sampling budget with the given PRNG seed.
/// - **Seed + iteration**: Seed with a `-N` suffix (for example, `"3RT5GH8KM2-7"`). Jumps directly to the Nth 1-based iteration.
/// - **Coverage row**: `U-N` prefix (for example, `"U-3"`). Replays the Nth 1-based coverage row (internally 0-indexed).
///
/// ```swift
/// .replay(42)                // UInt64 literal
/// .replay("3RT5GH8KM2")      // seed only, runs full budget
/// .replay("3RT5GH8KM2-7")    // seed with iteration (reproduces in one step)
/// .replay("U-3")              // coverage row replay
/// ```
public enum ReplaySeed: Sendable {
    /// A raw numeric seed.
    case numeric(UInt64)
    /// An encoded seed string, optionally with an iteration suffix or coverage-row prefix.
    case encoded(String)

    /// Distinguishes sampling replays (seed plus optional iteration) from coverage replays (row index).
    public enum Resolved: Sendable {
        /// Replay a sampling run with the given seed, optionally jumping to a specific iteration.
        case sampling(seed: UInt64, iteration: Int?)
        /// Replay a coverage row by 0-based index.
        case coverage(row: Int)

        /// The PRNG seed for sampling replays, or `nil` for coverage replays.
        public var seed: UInt64? {
            switch self {
                case let .sampling(seed, _): seed
                case .coverage: nil
            }
        }

        /// The iteration for sampling replays, or `nil` when absent or for coverage replays.
        public var iteration: Int? {
            switch self {
                case let .sampling(_, iteration): iteration
                case .coverage: nil
            }
        }

        /// Encodes this resolved seed to its canonical wire-format string.
        public var encoded: String {
            switch self {
                case let .sampling(seed, iteration):
                    if let iteration {
                        ReplaySeed.encode(seed: seed, iteration: iteration)
                    } else {
                        ReplaySeed.encodeRawSeed(seed)
                    }
                case let .coverage(row):
                    ReplaySeed.encodeCoverageRow(row)
            }
        }

        /// Decodes an encoded replay string, probing coverage-row format first, then sampling format.
        ///
        /// Returns `nil` when the string matches neither format.
        public static func decode(_ encoded: String) -> Resolved? {
            if let row = ReplaySeed.decodeCoverageRow(encoded) {
                return .coverage(row: row)
            }
            if let (seed, iteration) = ReplaySeed.decodeWithIteration(encoded) {
                return .sampling(seed: seed, iteration: iteration)
            }
            return nil
        }

        /// Encodes a coverage-phase failure from a 1-based iteration count to a 0-based coverage row.
        public static func encodeCoverageIteration(_ iteration: Int) -> String {
            Resolved.coverage(row: iteration - 1).encoded
        }
    }

    /// Resolves the seed to its decoded components.
    ///
    /// - Returns: The resolved form, or `nil` if the encoded string is invalid.
    public func resolve() -> Resolved? {
        switch self {
            case let .numeric(value):
                .sampling(seed: value, iteration: nil)
            case let .encoded(string):
                Resolved.decode(string)
        }
    }

    // MARK: - Encoding

    /// Encodes a bare `UInt64` seed as a Crockford Base32 string.
    public static func encodeRawSeed(_ value: UInt64) -> String {
        encode(value)
    }

    /// Encodes a seed and iteration into a combined replay string (for example, `"1A-7"`).
    package static func encode(seed: UInt64, iteration: Int) -> String {
        "\(encode(seed))-\(iteration)"
    }

    /// Decodes a replay string into a seed and optional iteration.
    ///
    /// Accepts both `"1A"` (iteration is nil) and `"1A-7"` (iteration is 7) formats. The iteration suffix is 1-based: `"1A-0"` is rejected rather than decoded into a `UInt64` underflow.
    package static func decodeWithIteration(_ string: String) -> (seed: UInt64, iteration: Int?)? {
        if let dashIndex = string.firstIndex(of: "-") {
            let seedPart = String(string[string.startIndex ..< dashIndex])
            let iterPart = String(string[string.index(after: dashIndex)...])
            guard let seed = decode(seedPart), let iteration = Int(iterPart), iteration >= 1 else {
                return nil
            }
            return (seed: seed, iteration: iteration)
        }
        guard let seed = decode(string) else { return nil }
        return (seed: seed, iteration: nil)
    }

    /// Encodes a 0-indexed coverage row as a replay string (for example, row 0 becomes `"U-1"`).
    ///
    /// The `U` prefix distinguishes coverage replays from sampling replays. `U` is not a valid Crockford Base32 digit and has no typo fallback mapping. The wire format is 1-indexed so `"U-0"` is never emitted.
    package static func encodeCoverageRow(_ row: Int) -> String {
        "U-\(row + 1)"
    }

    /// Decodes a `U`-prefixed coverage replay string into a 0-indexed row index (for example, `"U-1"` becomes 0).
    ///
    /// Accepts both `"U-1"` (current format) and `"U1"` (legacy format without dash). Returns `nil` if the string does not start with `U` or the number is not a positive integer.
    package static func decodeCoverageRow(_ string: String) -> Int? {
        guard let first = string.first, first == "U" || first == "u" else { return nil }
        var rowPart = String(string.dropFirst())
        if rowPart.hasPrefix("-") { rowPart = String(rowPart.dropFirst()) }
        guard let row = Int(rowPart), row >= 1 else { return nil }
        return row - 1
    }

    // MARK: - Crockford Base32 Primitives

    private static let alphabet: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "A", "B", "C", "D", "E", "F",
        "G", "H", "J", "K", "M", "N", "P", "Q",
        "R", "S", "T", "V", "W", "X", "Y", "Z",
    ]

    /// Encodes a `UInt64` as a Crockford Base32 string with no padding and no leading zeros.
    package static func encode(_ value: UInt64) -> String {
        if value == 0 { return "0" }
        var characters: [Character] = []
        characters.reserveCapacity(13)
        var remaining = value
        while remaining > 0 {
            let digit = Int(remaining % 32)
            characters.append(alphabet[digit])
            remaining /= 32
        }
        characters.reverse()
        return String(characters)
    }

    /// Decodes a Crockford Base32 string to a `UInt64`.
    ///
    /// Case-insensitive. Maps `I` and `L` to `1`, and `O` to `0` per the Crockford spec.
    /// Returns `nil` on invalid characters, empty input, or overflow.
    package static func decode(_ string: String) -> UInt64? {
        if string.isEmpty { return nil }
        var result: UInt64 = 0
        for character in string {
            guard let digitValue = decodeCharacter(character) else { return nil }
            let (shifted, shiftOverflow) = result.multipliedReportingOverflow(by: 32)
            if shiftOverflow { return nil }
            let (added, addOverflow) = shifted.addingReportingOverflow(UInt64(digitValue))
            if addOverflow { return nil }
            result = added
        }
        return result
    }

    private static func decodeCharacter(_ character: Character) -> Int? {
        switch character.uppercased().first ?? character {
            case "0", "O": 0
            case "1", "I", "L": 1
            case "2": 2
            case "3": 3
            case "4": 4
            case "5": 5
            case "6": 6
            case "7": 7
            case "8": 8
            case "9": 9
            case "A": 10
            case "B": 11
            case "C": 12
            case "D": 13
            case "E": 14
            case "F": 15
            case "G": 16
            case "H": 17
            case "J": 18
            case "K": 19
            case "M": 20
            case "N": 21
            case "P": 22
            case "Q": 23
            case "R": 24
            case "S": 25
            case "T": 26
            case "V": 27
            case "W": 28
            case "X": 29
            case "Y": 30
            case "Z": 31
            default: nil
        }
    }
}

extension ReplaySeed: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self = .numeric(value)
    }
}

extension ReplaySeed: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .encoded(value)
    }
}
