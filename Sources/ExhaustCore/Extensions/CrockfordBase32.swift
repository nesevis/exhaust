/// Crockford Base32 encoding and decoding for `UInt64` values.
///
/// Uses the alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ` — excludes `I`, `L`, `O`, `U`
/// to avoid visual ambiguity with `1`, `1`, `0`, and `V`. Case-insensitive on decode.
/// A `UInt64` encodes to at most 13 characters.
package enum CrockfordBase32 {
    // MARK: - Encoding

    private static let alphabet: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "A", "B", "C", "D", "E", "F",
        "G", "H", "J", "K", "M", "N", "P", "Q",
        "R", "S", "T", "V", "W", "X", "Y", "Z",
    ]

    /// Encodes a `UInt64` as a Crockford Base32 string.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: An uppercase Crockford Base32 string with no padding. Leading zeros are omitted.
    public static func encode(_ value: UInt64) -> String {
        if value == 0 { return "0" }

        // A UInt64 needs at most 13 base-32 digits (ceil(64/5)).
        // Extract 5-bit groups from most significant end.
        var characters: [Character] = []
        characters.reserveCapacity(13)
        var remaining = value
        while remaining > 0 {
            let digit = Int(remaining % 32)
            characters.append(alphabet[digit])
            remaining /= 32
        }
        // Digits were appended least-significant first; reverse for big-endian order.
        characters.reverse()
        return String(characters)
    }

    // MARK: - Decoding

    /// Decodes a Crockford Base32 string to a `UInt64`.
    ///
    /// Case-insensitive. Maps `I` and `L` to `1`, and `O` to `0` per the Crockford spec.
    /// Returns `nil` on invalid characters, empty input, or overflow.
    public static func decode(_ string: String) -> UInt64? {
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

    /// Maps a single character to its 5-bit value, or `nil` if invalid.
    private static func decodeCharacter(_ character: Character) -> Int? {
        switch character {
        case "0", "o", "O":
            0
        case "1", "i", "I", "l", "L":
            1
        case "2":
            2
        case "3":
            3
        case "4":
            4
        case "5":
            5
        case "6":
            6
        case "7":
            7
        case "8":
            8
        case "9":
            9
        case "a", "A":
            10
        case "b", "B":
            11
        case "c", "C":
            12
        case "d", "D":
            13
        case "e", "E":
            14
        case "f", "F":
            15
        case "g", "G":
            16
        case "h", "H":
            17
        case "j", "J":
            18
        case "k", "K":
            19
        case "m", "M":
            20
        case "n", "N":
            21
        case "p", "P":
            22
        case "q", "Q":
            23
        case "r", "R":
            24
        case "s", "S":
            25
        case "t", "T":
            26
        case "v", "V":
            27
        case "w", "W":
            28
        case "x", "X":
            29
        case "y", "Y":
            30
        case "z", "Z":
            31
        default:
            nil
        }
    }
}
