//
//  ReflectiveGenerator+Strings.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

@_spi(ExhaustInternal) import ExhaustCore

public extension ReflectiveGenerator {
    static func character(in range: ClosedRange<Character>? = nil) -> ReflectiveGenerator<Character> {
        if let range {
            let charMin = range.lowerBound.unicodeScalars.min()?.value ?? 0
            let charMax = range.upperBound.unicodeScalars.max()?.value ?? 0
            return Gen.chooseCharacter(in: charMin.bitPattern64 ... charMax.bitPattern64)
        }
        return Gen.chooseCharacter()
    }

    static func string(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        if let length {
            return Gen.arrayOf(.character(), within: length, scaling: scaling)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(.character())
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }

    static func ascii(length: ClosedRange<UInt64>? = nil, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<String> {
        if let length {
            return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]), within: length, scaling: scaling)
                .mapped(forward: { String($0) }, backward: { Array($0) })
        }
        return Gen.arrayOf(Gen.chooseCharacter(in: Character.bitPatternRanges[0]))
            .mapped(forward: { String($0) }, backward: { Array($0) })
    }
}
