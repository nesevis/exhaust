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

@_spi(ExhaustInternal) import ExhaustCore

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

    static func slice<C: Collection>(
        _ gen: ReflectiveGenerator<C>,
    ) -> ReflectiveGenerator<C.SubSequence> where Value == C.SubSequence {
        Gen.slice(gen)
    }

    static func shuffled(
        _ gen: ReflectiveGenerator<Value>,
    ) -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffled(gen)
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

    func shuffled() -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffled(self)
    }

    /// Picks a random element from the generated collection.
    ///
    /// Generates a collection, then selects one element uniformly at random.
    /// The backward pass finds the element's index for reflection.
    ///
    /// ```swift
    /// let randomLetter = #gen(.asciiString(length: 1...10)).element()
    /// ```
    func element() -> ReflectiveGenerator<Value.Element> where Value: Collection, Value.Element: Equatable, Value.Index == Int {
        // FIXME: This is not reflective
        bind { Gen.choose(from: $0) }
    }

    /// Picks a random element from the generated collection (non-Equatable variant).
    ///
    /// Same as ``element()`` but for collections whose elements don't conform to `Equatable`.
    /// The backward pass is best-effort since elements can't be compared by value.
    func element() -> ReflectiveGenerator<Value.Element> where Value: Collection, Value.Index == Int {
        // FIXME: This is not reflective
        bind { Gen.choose(from: $0) }
    }
}
