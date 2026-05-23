//
//  ReflectiveGenerator+Collections.swift
//  Exhaust
//

import ExhaustCore

// MARK: - Static collection generators

public extension ReflectiveGenerator {
    /// Creates a generator that produces arrays of random elements with size-scaled length.
    ///
    /// The array length scales with the interpreter's size parameter (1–100), producing shorter arrays early in a test run and longer ones later.
    ///
    /// ```swift
    /// let gen = #gen(.array(.int(in: 0...10)))
    /// ```
    ///
    /// - Parameter gen: Generator for each array element.
    /// - Returns: A generator producing arrays of random length.
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>
    ) -> ReflectiveGenerator<[Element]> where Output == [Element] {
        Gen.arrayOf(gen.gen).wrapped
    }

    /// Creates a generator that produces arrays with length within a specified range.
    ///
    /// ```swift
    /// let gen = #gen(.array(.bool(), length: 2...5))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each array element.
    ///   - length: The allowed range of array lengths.
    ///   - scaling: How array length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing arrays with length in the given range.
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<[Element]> where Output == [Element] {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        return Gen.arrayOf(
            gen.gen,
            within: UInt64(length.lowerBound) ... UInt64(length.upperBound),
            scaling: scaling
        ).wrapped
    }

    /// Creates a generator that produces arrays of an exact fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.array(.int(in: 0...9), length: 3))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each array element.
    ///   - length: The exact number of elements in each generated array.
    /// - Returns: A generator producing arrays of the specified length.
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: UInt64
    ) -> ReflectiveGenerator<[Element]> where Output == [Element] {
        Gen.arrayOf(gen.gen, exactly: length).wrapped
    }

    /// Creates a generator that produces arrays of an exact fixed length.
    ///
    /// ```swift
    /// let gen = #gen(.array(.int(in: 0...9), length: 3))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each array element.
    ///   - length: The exact number of elements in each generated array.
    /// - Returns: A generator producing arrays of the specified length.
    static func array<Element>(
        _ gen: ReflectiveGenerator<Element>,
        length: Int
    ) -> ReflectiveGenerator<[Element]> where Output == [Element] {
        precondition(length >= 0, "Length must be non-negative")
        return array(gen, length: UInt64(length))
    }

    /// Creates a generator that produces sets of random elements with size-scaled count.
    ///
    /// Elements are deduplicated by hash, so the generated set may be smaller than the requested count if the element generator produces duplicates.
    ///
    /// ```swift
    /// let gen = #gen(.set(.element(from: ["a", "b", "c", "d"])))
    /// ```
    ///
    /// - Parameter gen: Generator for each set element.
    /// - Returns: A generator producing sets of random size.
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>
    ) -> ReflectiveGenerator<Set<Element>> where Output == Set<Element> {
        Gen.setOf(gen.gen).wrapped
    }

    /// Creates a generator that produces sets with count within a specified range.
    ///
    /// ```swift
    /// let gen = #gen(.set(.int(in: 0...100), count: 1...5))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each set element.
    ///   - count: The allowed range of set sizes.
    ///   - scaling: How set size scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing sets with count in the given range.
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Set<Element>> where Output == Set<Element> {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        let range = UInt64(count.lowerBound) ... UInt64(count.upperBound)
        return Gen.setOf(gen.gen, within: range, scaling: scaling).wrapped
    }

    /// Creates a generator that produces sets of an exact fixed count.
    ///
    /// ```swift
    /// let gen = #gen(.set(.int(in: 0...100), count: UInt64(3)))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each set element.
    ///   - count: The exact number of elements in each generated set.
    /// - Returns: A generator producing sets of the specified size.
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: UInt64
    ) -> ReflectiveGenerator<Set<Element>> where Output == Set<Element> {
        Gen.setOf(gen.gen, exactly: count).wrapped
    }

    /// Creates a generator that produces sets of an exact fixed count.
    ///
    /// ```swift
    /// let gen = #gen(.set(.int(in: 0...100), count: 3))
    /// ```
    ///
    /// - Parameters:
    ///   - gen: Generator for each set element.
    ///   - count: The exact number of elements in each generated set.
    /// - Returns: A generator producing sets of the specified size.
    static func set<Element: Hashable>(
        _ gen: ReflectiveGenerator<Element>,
        count: Int
    ) -> ReflectiveGenerator<Set<Element>> where Output == Set<Element> {
        precondition(count >= 0, "Count must be non-negative")
        return set(gen, count: UInt64(count))
    }

    /// Creates a generator that produces dictionaries from key and value generators.
    ///
    /// Array length (and thus dictionary size) is size-scaled. Keys are deduplicated by hash — if the key generator produces duplicates, the first value is kept.
    ///
    /// There is no instance-method counterpart (unlike ``array()`` and ``set()``). A chaining `.dictionary()` on a tuple generator would silently drop entries on key collision, with no way to control or detect how many entries survive. The static form keeps pair generation internal so the collision semantics stay hidden from the call site.
    ///
    /// ```swift
    /// let gen = #gen(.dictionary(.asciiString(), .int(in: 0...100)))
    /// ```
    ///
    /// - Parameters:
    ///   - keyGen: Generator for dictionary keys.
    ///   - valueGen: Generator for dictionary values.
    /// - Returns: A generator producing dictionaries of random size.
    static func dictionary<Key: Hashable, DictValue>(
        _ keyGen: ReflectiveGenerator<Key>,
        _ valueGen: ReflectiveGenerator<DictValue>
    ) -> ReflectiveGenerator<[Key: DictValue]> where Output == [Key: DictValue] {
        Gen.dictionaryOf(keyGen.gen, valueGen.gen).wrapped
    }

    /// Creates a generator that produces random contiguous slices of a generated collection.
    ///
    /// Generates the full collection, then selects a random start index and length to produce a `SubSequence`.
    ///
    /// ```swift
    /// let gen = #gen(.slice(of: .array(.int(in: 0...9), length: 5...10)))
    /// ```
    ///
    /// - Parameter gen: Generator for the source collection to slice.
    /// - Returns: A generator producing random sub-sequences.
    static func slice<C: Collection>(
        of gen: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<C.SubSequence> where Output == C.SubSequence {
        Gen.slice(of: gen.gen).wrapped
    }

    /// Creates a generator that produces random contiguous slices of a fixed collection.
    ///
    /// The collection is captured at construction time. Each generated value is a non-empty contiguous sub-sequence.
    ///
    /// ```swift
    /// let gen = #gen(.slice(of: ["a", "b", "c", "d", "e"]))
    /// ```
    ///
    /// - Parameter collection: The collection to slice.
    /// - Returns: A generator producing random sub-sequences of the collection.
    static func slice<C: Collection>(
        of collection: C
    ) -> ReflectiveGenerator<C.SubSequence> where Output == C.SubSequence {
        Gen.slice(of: collection).wrapped
    }

    /// Creates a generator that produces randomly shuffled versions of a generated collection.
    ///
    /// Generates the collection, then applies a random permutation.
    ///
    /// ```swift
    /// let gen = #gen(.shuffled(.array(.int(in: 0...9))))
    /// ```
    ///
    /// - Parameter gen: Generator for the source collection to shuffle.
    /// - Returns: A generator producing shuffled arrays.
    static func shuffled(
        _ gen: ReflectiveGenerator<Output>
    ) -> ReflectiveGenerator<[Output.Element]> where Output: Collection {
        Gen.shuffled(gen.gen).wrapped
    }
}

// MARK: - Instance methods for chaining

public extension ReflectiveGenerator {
    /// Wraps this element generator to produce arrays with size-scaled length.
    ///
    /// ```swift
    /// let numbers = #gen(.int(in: 0...99)).array()
    /// ```
    ///
    /// - Returns: A generator producing arrays of this generator's values.
    func array() -> ReflectiveGenerator<[Output]> {
        Gen.arrayOf(gen).wrapped
    }

    /// Wraps this element generator to produce arrays with length in a specified range.
    ///
    /// ```swift
    /// let shortLists = #gen(.int(in: 0...9)).array(length: 1...5)
    /// ```
    ///
    /// - Parameters:
    ///   - length: The allowed range of array lengths.
    ///   - scaling: How array length scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing arrays with length in the given range.
    func array(
        length: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<[Output]> {
        precondition(length.lowerBound >= 0, "Length must be non-negative")
        let range = UInt64(length.lowerBound) ... UInt64(length.upperBound)
        return Gen.arrayOf(gen, within: range, scaling: scaling).wrapped
    }

    /// Wraps this element generator to produce arrays of an exact fixed length.
    ///
    /// ```swift
    /// let pair = #gen(.bool()).array(length: 2)
    /// ```
    ///
    /// - Parameter length: The exact number of elements in each generated array.
    /// - Returns: A generator producing arrays of the specified length.
    func array(length: UInt64) -> ReflectiveGenerator<[Output]> {
        Gen.arrayOf(gen, exactly: length).wrapped
    }

    /// Wraps this element generator to produce arrays of an exact fixed length.
    ///
    /// ```swift
    /// let pair = #gen(.bool()).array(length: 2)
    /// ```
    ///
    /// - Parameter length: The exact number of elements in each generated array.
    /// - Returns: A generator producing arrays of the specified length.
    func array(length: Int) -> ReflectiveGenerator<[Output]> {
        precondition(length >= 0, "Length must be non-negative")
        return array(length: UInt64(length))
    }

    /// Wraps this element generator to produce sets with size-scaled count.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...100)).set()
    /// ```
    ///
    /// - Returns: A generator producing sets of this generator's values.
    func set() -> ReflectiveGenerator<Set<Output>> where Output: Hashable {
        Gen.setOf(gen).wrapped
    }

    /// Wraps this element generator to produce sets with count in a specified range.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...100)).set(count: 1...5)
    /// ```
    ///
    /// - Parameters:
    ///   - count: The allowed range of set sizes.
    ///   - scaling: How set size scales with the size parameter. Defaults to `.linear`.
    /// - Returns: A generator producing sets with count in the given range.
    func set(
        count: ClosedRange<Int>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Set<Output>> where Output: Hashable {
        precondition(count.lowerBound >= 0, "Count must be non-negative")
        let range = UInt64(count.lowerBound) ... UInt64(count.upperBound)
        return Gen.setOf(gen, within: range, scaling: scaling).wrapped
    }

    /// Wraps this element generator to produce sets of an exact fixed count.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...100)).set(count: UInt64(3))
    /// ```
    ///
    /// - Parameter count: The exact number of elements in each generated set.
    /// - Returns: A generator producing sets of the specified size.
    func set(count: UInt64) -> ReflectiveGenerator<Set<Output>> where Output: Hashable {
        Gen.setOf(gen, exactly: count).wrapped
    }

    /// Wraps this element generator to produce sets of an exact fixed count.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...100)).set(count: 3)
    /// ```
    ///
    /// - Parameter count: The exact number of elements in each generated set.
    /// - Returns: A generator producing sets of the specified size.
    func set(count: Int) -> ReflectiveGenerator<Set<Output>> where Output: Hashable {
        precondition(count >= 0, "Count must be non-negative")
        return set(count: UInt64(count))
    }

    /// Wraps this collection generator to produce random contiguous slices.
    ///
    /// ```swift
    /// let gen = #gen(.int(in: 0...9).array(length: 3...8).slice())
    /// ```
    ///
    /// - Returns: A generator producing non-empty sub-sequences of the generated collection.
    func slice() -> ReflectiveGenerator<Output.SubSequence> where Output: Collection {
        Gen.slice(of: gen).wrapped
    }

    /// Wraps this collection generator to produce randomly shuffled arrays.
    ///
    /// ```swift
    /// let shuffled = #gen(.int(in: 1...10)).array(length: 5).shuffled()
    /// ```
    ///
    /// - Returns: A generator producing shuffled arrays of this collection's elements.
    func shuffled() -> ReflectiveGenerator<[Output.Element]> where Output: Collection {
        Gen.shuffled(gen).wrapped
    }

    /// Picks a random element from a fixed collection.
    ///
    /// The collection is captured at construction time. The backward pass finds the element's index via hash-based O(1) lookup for reflection and test case reduction.
    ///
    /// ```swift
    /// let gen = #gen(.element(from: ["♠", "♥", "♦", "♣"]))
    /// ```
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where Output == C.Element, C.Element: Hashable {
        Gen.element(from: collection).wrapped
    }

    /// Picks a random element from a fixed collection.
    ///
    /// The collection is captured at construction time. The backward pass finds the element's index via linear equality scan for reflection and test case reduction.
    ///
    /// ```swift
    /// let gen = #gen(.element(from: [1.0, 2.5, 3.14]))
    /// ```
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where Output == C.Element, C.Element: Equatable {
        Gen.element(from: collection).wrapped
    }

    /// Picks a random element from a fixed collection, identified by a hashable key path for O(1) reflection.
    ///
    /// The collection is captured at construction time. The backward pass identifies the element via hash-based dictionary lookup on the extracted value, enabling reflection for types that are not ``Hashable`` themselves.
    ///
    /// ```swift
    /// let gen = #gen(.element(from: configs, id: \.id))
    /// ```
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A key path to a hashable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C,
        id path: KeyPath<C.Element, some Hashable>
    ) -> ReflectiveGenerator<C.Element> where Output == C.Element {
        Gen.element(from: collection, id: path).wrapped
    }

    /// Picks a random element from a fixed collection, identified by an equatable key path for reflection.
    ///
    /// The collection is captured at construction time. The backward pass identifies the element by linear scan comparing the extracted value, enabling reflection for types that are not ``Equatable``.
    ///
    /// ```swift
    /// let gen = #gen(.element(from: configs, id: \.name))
    /// ```
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A key path to an equatable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C,
        id path: KeyPath<C.Element, some Equatable>
    ) -> ReflectiveGenerator<C.Element> where Output == C.Element {
        Gen.element(from: collection, id: path).wrapped
    }
}
