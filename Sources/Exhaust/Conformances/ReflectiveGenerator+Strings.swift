//
//  ReflectiveGenerator+Strings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

public extension ReflectiveGenerator where Value == Character {
    static func character(in range: ClosedRange<Value>? = nil) -> ReflectiveGenerator<Value> {
        if let range {
            let charMin = range.lowerBound.unicodeScalars.min()?.value ?? 0
            let charMax = range.upperBound.unicodeScalars.max()?.value ?? 0
            return Gen.chooseCharacter(in: charMin.bitPattern64...charMax.bitPattern64)
        }
        return Gen.chooseCharacter()
    }
    
    // This will conflict with the string representation
//    static func ascii() -> ReflectiveGenerator<Value> {
//        Gen.chooseCharacter(in: Character.bitPatternRanges[0])
//    }
}

public extension ReflectiveGenerator where Value == String {
    static func string(length: ClosedRange<UInt64>? = nil) -> ReflectiveGenerator<Value> {
        if let length {
            return Gen.arrayOf(.character(), within: length)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(.character())
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
    
    static func ascii(length: ClosedRange<UInt64>? = nil) -> ReflectiveGenerator<Value> {
        if let length {
            return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]), within: length)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]))
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
}
