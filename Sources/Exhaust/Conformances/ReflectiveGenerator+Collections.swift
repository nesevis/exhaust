//
//  ReflectiveGenerator+Collections.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

import ExhaustCore

// MARK: - Static collection generators

public extension ReflectiveGenerator {
    /// Creates a generator that produces arrays of random elements with size-scaled length.
    ///
    /// The array length scales with the interpreter's size parameter (1–100), producing shorter arrays early in a test run and longer ones later.
    ///
    /// ```swift
    /// let arrays = ReflectiveGenerator.array(.int(in: 0...10))
    /// ```
    ///
    /// - Parameter gen: Generator for each array element
    /// - Returns: A generator producing arrays of random length
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen)
    }

    /// Creates a generator that produces arrays with length within a specified range.
    ///
    /// ```swift
    /// let pairs = ReflectiveGenerator.array(.bool(), length: 2...5)
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each array element
    ///   - length: The allowed range of array lengths
    ///   - scaling: How array length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing arrays with length in the given range
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(gen, within: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    /// Creates a generator that produces arrays of an exact fixed length.
    ///
    /// ```swift
    /// let triple = ReflectiveGenerator.array(.int(in: 0...9), length: 3)
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each array element
    ///   - length: The exact number of elements in each generated array
    /// - Returns: A generator producing arrays of the specified length
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: UInt64
    ) -> ReflectiveGenerator<[Element]> where Value == [Element] {
        Gen.arrayOf(gen, exactly: length)
    }

    /// Creates a generator that produces sets of random elements with size-scaled count.
    ///
    /// Elements are deduplicated by hash, so the generated set may be smaller than the requested count if the element generator produces duplicates.
    ///
    /// ```swift
    /// let tags = ReflectiveGenerator.set(.element(from: ["a", "b", "c", "d"]))
    /// ```
    ///
    /// - Parameter gen: Generator for each set element
    /// - Returns: A generator producing sets of random size
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        Gen.setOf(gen)
    }

    /// Creates a generator that produces sets with count within a specified range.
    ///
    /// - Parameters:
    ///   - gen: Generator for each set element
    ///   - count: The allowed range of set sizes
    ///   - scaling: How set size scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing sets with count in the given range
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        return Gen.setOf(gen, within: UInt64(count.lowerBound) ... UInt64(count.upperBound), scaling: scaling)
    }

    /// Creates a generator that produces sets of an exact fixed count.
    ///
    /// - Parameters:
    ///   - gen: Generator for each set element
    ///   - count: The exact number of elements in each generated set
    /// - Returns: A generator producing sets of the specified size
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: UInt64
    ) -> ReflectiveGenerator<Set<Element>> where Value == Set<Element> {
        Gen.setOf(gen, exactly: count)
    }

    /// Creates a generator that produces dictionaries from key and value generators.
    ///
    /// Array length (and thus dictionary size) is size-scaled. Keys are deduplicated by hash — if the key generator produces duplicates, later values overwrite earlier ones.
    ///
    /// ```swift
    /// let config = ReflectiveGenerator.dictionary(.asciiString(), .int(in: 0...100))
    /// ```
    ///
    /// - Parameters:
    ///   - keyGen: Generator for dictionary keys
    ///   - valueGen: Generator for dictionary values
    /// - Returns: A generator producing dictionaries of random size
    static func dictionary<Key: Hashable, DictValue>(
        _ keyGen: ReflectiveGenerator<Key>,
        _ valueGen: ReflectiveGenerator<DictValue>
    ) -> ReflectiveGenerator<[Key: DictValue]> where Value == [Key: DictValue] {
        Gen.dictionaryOf(keyGen, valueGen)
    }

    /// Creates a generator that produces random contiguous slices of a generated collection.
    ///
    /// Generates the full collection, then selects a random start index and length to produce a `SubSequence`.
    ///
    /// - Parameter gen: Generator for the source collection to slice
    /// - Returns: A generator producing random sub-sequences
    static func slice<C: Collection>(
        _ gen: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<C.SubSequence> where Value == C.SubSequence {
        Gen.slice(of: gen)
    }

    /// Creates a generator that produces randomly shuffled versions of a generated collection.
    ///
    /// Generates the collection, then applies a random permutation.
    ///
    /// - Parameter gen: Generator for the source collection to shuffle
    /// - Returns: A generator producing shuffled arrays
    static func shuffled(
        _ gen: ReflectiveGenerator<Value>
    ) -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffled(gen)
    }
}

// MARK: - Instance methods for chaining

public extension ReflectiveGenerator where Operation == ReflectiveOperation {
    /// Wraps this element generator to produce arrays with size-scaled length.
    ///
    /// ```swift
    /// let numbers = #gen(.int(in: 0...99)).array()
    /// ```
    ///
    /// - Returns: A generator producing arrays of this generator's values
    func array() -> ReflectiveGenerator<[Value]> {
        Gen.arrayOf(self)
    }

    /// Wraps this element generator to produce arrays with length in a specified range.
    ///
    /// ```swift
    /// let shortLists = #gen(.int(in: 0...9)).array(length: 1...5)
    /// ```
    ///
    /// - Parameters:
    ///   - length: The allowed range of array lengths
    ///   - scaling: How array length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing arrays with length in the given range
    func array(length: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<[Value]> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(self, within: UInt64(length.lowerBound) ... UInt64(length.upperBound), scaling: scaling)
    }

    /// Wraps this element generator to produce arrays of an exact fixed length.
    ///
    /// ```swift
    /// let pair = #gen(.bool()).array(length: 2)
    /// ```
    ///
    /// - Parameter length: The exact number of elements in each generated array
    /// - Returns: A generator producing arrays of the specified length
    func array(length: UInt64) -> ReflectiveGenerator<[Value]> {
        Gen.arrayOf(self, exactly: length)
    }

    /// Wraps this element generator to produce sets with size-scaled count.
    ///
    /// - Returns: A generator producing sets of this generator's values
    func set() -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        Gen.setOf(self)
    }

    /// Wraps this element generator to produce sets with count in a specified range.
    ///
    /// - Parameters:
    ///   - count: The allowed range of set sizes
    ///   - scaling: How set size scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing sets with count in the given range
    func set(count: ClosedRange<Int>, scaling: SizeScaling<UInt64> = .linear) -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        return Gen.setOf(self, within: UInt64(count.lowerBound) ... UInt64(count.upperBound), scaling: scaling)
    }

    /// Wraps this element generator to produce sets of an exact fixed count.
    ///
    /// - Parameter count: The exact number of elements in each generated set
    /// - Returns: A generator producing sets of the specified size
    func set(count: UInt64) -> ReflectiveGenerator<Set<Value>> where Value: Hashable {
        Gen.setOf(self, exactly: count)
    }

    /// Wraps this collection generator to produce randomly shuffled arrays.
    ///
    /// ```swift
    /// let shuffled = #gen(.int(in: 1...10)).array(length: 5).shuffled()
    /// ```
    ///
    /// - Returns: A generator producing shuffled arrays of this collection's elements
    func shuffled() -> ReflectiveGenerator<[Value.Element]> where Value: Collection {
        Gen.shuffled(self)
    }

    /// Picks a random element from a fixed collection.
    ///
    /// This is fully reflective — the collection is known at construction time, so the backward pass can find the element's index for reflection and test case reduction.
    ///
    /// ```swift
    /// let suit = ReflectiveGenerator.element(from: ["♠", "♥", "♦", "♣"])
    /// ```
    ///
    /// - Parameter collection: The collection to pick elements from
    /// - Returns: A generator that produces random elements from the collection
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where Value == C.Element, C.Element: Hashable {
        Gen.element(from: collection)
    }

    /// Picks a random element from a fixed collection (non-Hashable variant).
    ///
    /// This is fully reflective — the collection is known at construction time, so the backward pass can find the element's index for reflection and test case reduction.
    ///
    /// - Parameter collection: The collection to pick elements from
    /// - Returns: A generator that produces random elements from the collection
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where Value == C.Element {
        Gen.element(from: collection)
    }
}
