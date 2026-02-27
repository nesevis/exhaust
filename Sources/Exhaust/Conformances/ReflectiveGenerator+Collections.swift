//
//  ReflectiveGenerator+Collections.swift
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

import ExhaustCore

public extension ReflectiveGenerator {
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen)
    }

    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear,
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(gen, within: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: UInt64,
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen, exactly: length)
    }

    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        Gen.setOf(gen)
    }

    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear,
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        return Gen.setOf(gen, within: UInt64(count.lowerBound) ... UInt64(count.upperBound), scaling: scaling)
    }

    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: UInt64,
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        Gen.setOf(gen, exactly: count)
    }

    static func dictionary<Key: Hashable, DictValue>(
        _ keyGen: ReflectiveGenerator<Key>,
        _ valueGen: ReflectiveGenerator<DictValue>,
    ) -> ReflectiveGenerator<[Key: DictValue]> where Value == [Key: DictValue] {
        Gen.dictionaryOf(keyGen, valueGen)
    }

    static func sub<C: Collection>(
        _ gen: ReflectiveGenerator<C>,
    ) -> ReflectiveGenerator<C.SubSequence> where Value == C.SubSequence {
        Gen.sub(gen)
    }

    static func shuffle(
        _ gen: ReflectiveGenerator<Value>,
    ) -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffle(gen)
    }

    static func element<C: Collection>(
        _ collection: C,
    ) -> ReflectiveGenerator<C.Element> where C.Index == Int {
        Gen.choose(from: collection)
    }
}

// MARK: - Instance methods for chaining

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    func array() -> ReflectiveGenerator<[Value]> {
        Gen.arrayOf(self)
    }

    func array(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<[Value]> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(self, within: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    func array(length: UInt64) -> ReflectiveGenerator<[Value]> {
        Gen.arrayOf(self, exactly: length)
    }

    func set() -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        Gen.setOf(self)
    }

    func set(count: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        return Gen.setOf(self, within: UInt64(count.lowerBound) ... UInt64(count.upperBound), scaling: scaling)
    }

    func set(count: UInt64) -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        Gen.setOf(self, exactly: count)
    }

    func shuffle() -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffle(self)
    }
}

public extension ReflectiveGenerator where Value: CaseIterable, Value.AllCases.Index == Int {
    static func cases(_ type: Value.Type) -> ReflectiveGenerator<Value> {
        Gen.choose(from: type.allCases)
    }
}
