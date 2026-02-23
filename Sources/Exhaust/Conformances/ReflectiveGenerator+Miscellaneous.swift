//
//  ReflectiveGenerator+Miscellaneous.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

// Extensions for:
// - UUID
// - CGFloat
// - Date
// - Simd types
// - ??

public extension ReflectiveGenerator {
    static func array<Element>(_ gen: ReflectiveGenerator<Element>) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen)
    }
    
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: ClosedRange<Int>
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(gen, within: UInt64(length.lowerBound)...UInt64(length.upperBound))
    }

    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: UInt64
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen, exactly: length)
    }

    static func dictionary<Key: Hashable, DictValue>(
        _ keyGen: ReflectiveGenerator<Key>,
        _ valueGen: ReflectiveGenerator<DictValue>
    ) -> ReflectiveGenerator<[Key: DictValue]> where Value == [Key: DictValue] {
        Gen.dictionaryOf(keyGen, valueGen)
    }
}
