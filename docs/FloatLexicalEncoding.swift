import Foundation

// MARK: - Float Lexical Encoding for Swift
// Based on Hypothesis's approach to float_to_lex

public struct FloatLexicalEncoding {
    
    // IEEE 754 constants
    private static let maxExponent: UInt64 = 0x7FF
    private static let bias: Int = 1023
    private static let mantissaBits: Int = 52
    
    // Precomputed tables for exponent encoding/decoding
    private static let encodingTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: Int(maxExponent) + 1)
        let sorted = (0...Int(maxExponent)).sorted { exponentKey($0) < exponentKey($1) }
        for (i, v) in sorted.enumerated() {
            table[v] = UInt16(i)
        }
        return table
    }()
    
    private static let decodingTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: encodingTable.count)
        for (i, v) in encodingTable.enumerated() {
            table[Int(v)] = UInt16(i)
        }
        return table
    }()
    
    // MARK: - Exponent Key
    
    /// Maps exponent to ordering position
    /// Positive exponents come first (small to large), then negative (large to small)
    private static func exponentKey(_ e: Int) -> Double {
        if e == Int(maxExponent) {
            return Double.infinity
        }
        let unbiased = e - bias
        if unbiased < 0 {
            return 10000 - Double(unbiased)
        } else {
            return Double(unbiased)
        }
    }
    
    // MARK: - Bit Reversal
    
    private static let reverseBitsTable: [UInt8] = {
        (0..<256).map { byte in
            var result: UInt8 = 0
            var b = byte
            for _ in 0..<8 {
                result <<= 1
                result |= b & 1
                b >>= 1
            }
            return result
        }
    }()
    
    /// Reverse all 64 bits of a UInt64
    public static func reverse64(_ v: UInt64) -> UInt64 {
        return (
            UInt64(reverseBitsTable[Int((v >> 0) & 0xFF)]) << 56 |
            UInt64(reverseBitsTable[Int((v >> 8) & 0xFF)]) << 48 |
            UInt64(reverseBitsTable[Int((v >> 16) & 0xFF)]) << 40 |
            UInt64(reverseBitsTable[Int((v >> 24) & 0xFF)]) << 32 |
            UInt64(reverseBitsTable[Int((v >> 32) & 0xFF)]) << 24 |
            UInt64(reverseBitsTable[Int((v >> 40) & 0xFF)]) << 16 |
            UInt64(reverseBitsTable[Int((v >> 48) & 0xFF)]) << 8 |
            UInt64(reverseBitsTable[Int((v >> 56) & 0xFF)]) << 0
        )
    }
    
    /// Reverse the lowest n bits
    private static func reverseBits(_ x: UInt64, _ n: Int) -> UInt64 {
        let reversed = reverse64(x)
        return reversed >> (64 - n)
    }
    
    // MARK: - Mantissa Update
    
    /// Apply mantissa transformations based on unbiased exponent
    private static func updateMantissa(_ unbiasedExponent: Int, _ mantissa: UInt64) -> UInt64 {
        var m = mantissa
        if unbiasedExponent <= 0 {
            m = reverseBits(m, 52)
        } else if unbiasedExponent <= 51 {
            let fractionalBits = 52 - unbiasedExponent
            let fractionalPart = m & ((1 << fractionalBits) - 1)
            m ^= fractionalPart
            m |= reverseBits(fractionalPart, fractionalBits)
        }
        return m
    }
    
    // MARK: - Exponent Encoding/Decoding
    
    private static func decodeExponent(_ e: UInt16) -> Int {
        return Int(encodingTable[Int(e)])
    }
    
    private static func encodeExponent(_ e: Int) -> UInt16 {
        return decodingTable[e]
    }
    
    // MARK: - Float <-> Int Conversion
    
    /// Reinterpret bits of a Double as UInt64
    public static func floatToInt(_ f: Double) -> UInt64 {
        return f.bitPattern
    }
    
    /// Reinterpret bits of a UInt64 as Double
    public static func intToFloat(_ i: UInt64) -> Double {
        return Double(bitPattern: i)
    }
    
    // MARK: - Simple Float Detection
    
    /// A "simple" float is an integer <= 2^56 that can be exactly represented
    public static func isSimple(_ f: Double) -> Bool {
        guard f.isFinite else { return false }
        let asInt = Int(f)
        return Double(asInt) == f && asInt >= 0 && asInt.bitWidth <= 56
    }
    
    // MARK: - Main Encoding Function
    
    /// Convert a float to a UInt64 for lexical ordering
    /// 
    /// Ordering properties:
    /// 1. NaNs are ordered after everything else
    /// 2. Infinity is ordered after every finite number
    /// 3. Positive floats come before negative
    /// 4. Finite numbers ordered by integer part first, then fractional part
    public static func floatToLex(_ f: Double) -> UInt64 {
        if isSimple(f) {
            return UInt64(f)
        }
        return baseFloatToLex(f)
    }
    
    private static func baseFloatToLex(_ f: Double) -> UInt64 {
        var bits = floatToInt(f)
        // Clear sign bit (we handle sign separately)
        bits &= (1 << 63) - 1
        
        let exponent = Int(bits >> 52)
        let mantissa = bits & ((1 << 52) - 1)
        
        // Transform mantissa based on exponent
        let transformedMantissa = updateMantissa(exponent - bias, mantissa)
        
        // Transform exponent for ordering
        let transformedExponent = encodeExponent(exponent)
        
        // Tag bit = 1 for non-simple floats, then encode
        return (1 << 63) | (UInt64(transformedExponent) << 52) | transformedMantissa
    }
    
    // MARK: - Decoding (for testing)
    
    /// Convert a lexically-ordered UInt64 back to a Double
    public static func lexToFloat(_ i: UInt64) -> Double {
        let hasFractionalPart = (i >> 63) != 0
        if !hasFractionalPart {
            // Simple case: just convert to float
            return Double(truncatingIfNeeded: i)
        }
        
        let exponentBits = Int((i >> 52) & ((1 << 11) - 1))
        let mantissa = i & ((1 << 52) - 1)
        
        let decodedExponent = decodeExponent(UInt16(exponentBits))
        let transformedMantissa = updateMantissa(decodedExponent - bias, mantissa)
        
        let resultBits = (UInt64(decodedExponent) << 52) | transformedMantissa
        return intToFloat(resultBits)
    }
}

// MARK: - Comparison Operators

public extension Double {
    /// Compare two floats using lexical ordering
    func lexCompare(to other: Double) -> Int {
        let lexSelf = FloatLexicalEncoding.floatToLex(self)
        let lexOther = FloatLexicalEncoding.floatToLex(other)
        
        if lexSelf < lexOther { return -1 }
        if lexSelf > lexOther { return 1 }
        return 0
    }
}

// MARK: - Example Usage

#if DEBUG
print("=== Float Lexical Encoding Examples ===\n")

let testFloats: [Double] = [
    0.0, 1.0, -1.0, 0.5, 2.0, 100.0,
    Double.infinity, -Double.infinity,
    Double.nan, Double.pi, -Double.pi
]

print("Float -> Lex encoding:")
for f in testFloats {
    let lex = FloatLexicalEncoding.floatToLex(f)
    print("  \(f.description.padding(toLength: 20, withPad: " ", startingAt: 0)) -> 0x\(String(lex, radix: 16, uppercase: true))")
}

print("\nSorted lexically:")
let sorted = testFloats.sorted { $0.lexCompare(to: $1) < 0 }
for f in sorted {
    print("  \(f)")
}

// Verify round-trip
print("\nRound-trip verification:")
for f in testFloats where f.isFinite && !f.isZero {
    let lex = FloatLexicalEncoding.floatToLex(f)
    let recovered = FloatLexicalEncoding.lexToFloat(lex)
    let match = f == recovered ? "✓" : "✗"
    print("  \(f) -> 0x\(String(lex, radix: 16)) -> \(recovered) \(match)")
}
#endif
