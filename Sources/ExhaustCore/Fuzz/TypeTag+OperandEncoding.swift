// Encodes trace-cmp operand words into choice-space bit patterns, for comparand substitution on the flat sequence.

package extension TypeTag {
    /// Encodes a harvested comparison-operand word as this tag's order-preserving bit pattern, or nil for a tag whose choice encoding does not correspond to an integer operand.
    ///
    /// The word carries the natural representation the system under test compared. Signed tags narrower than 64 bits reinterpret the word's low bytes at their own width, so a zero-extended negative from a narrow comparison decodes to its true value; the full-width signed tags read the word as 64-bit two's complement, so a zero-extended narrow negative reads as a large positive and is rejected by the caller's range check (the recorded trace-cmp width limitation). Floating-point, date, character, and control tags return nil: a comparison operand cannot name their choice encodings.
    func operandBitPattern(fromWord word: UInt64) -> UInt64? {
        switch self {
            case .uint, .uint64, .bits:
                return word
            case .uint32:
                return word <= UInt64(UInt32.max) ? word : nil
            case .uint16:
                return word <= UInt64(UInt16.max) ? word : nil
            case .uint8:
                return word <= UInt64(UInt8.max) ? word : nil
            case .int, .int64:
                return Int64(bitPattern: word).bitPattern64
            case .int32:
                guard word <= UInt64(UInt32.max) else { return nil }
                return Int32(truncatingIfNeeded: word).bitPattern64
            case .int16:
                guard word <= UInt64(UInt16.max) else { return nil }
                return Int16(truncatingIfNeeded: word).bitPattern64
            case .int8:
                guard word <= UInt64(UInt8.max) else { return nil }
                return Int8(truncatingIfNeeded: word).bitPattern64
            case .double, .float, .float16, .date, .character, .depthControl, .laneControl:
                return nil
        }
    }
}
