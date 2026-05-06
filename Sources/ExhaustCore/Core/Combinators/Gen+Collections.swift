// Operations for generating collections like arrays and dictionaries.
// These combinators handle the complexities of generating structured data with proper reduction behavior.

package extension Gen {
    /// Creates a generator for an array of random values.
    ///
    /// This implementation is stack-safe and can generate very large arrays without overflowing.
    /// It works by first generating a random length, then using a primitive `.sequence` operation which the interpreter can execute iteratively.
    ///
    /// The array length is controlled by the provided length generator, which defaults to a size-based range if not specified.
    ///
    /// - Parameters:
    ///   - elementGenerator: A self-contained generator for the elements of the array.
    ///   - length: Optional generator for the array length. Defaults to size-based length.
    /// - Returns: A generator that produces an array of elements.
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        _ length: ReflectiveGenerator<UInt64>? = nil
    ) -> ReflectiveGenerator<[Output]> {
        // Use `bind` to get the result of the length generator.
        let sequenceOperation = ReflectiveOperation.sequence(
            length: length ?? Gen.getSize { Gen.chooseDerived(in: 0 ... $0) },
            gen: elementGenerator.erase()
        )
        // Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOperation) { result in
            guard let array = result as? [Output] else {
                throw GeneratorError.typeMismatch(
                    expected: String(describing: type(of: [Output].self)),
                    actual: String(describing: type(of: result))
                )
            }
            return .pure(array)
        }
    }

    /// Creates a generator for an array with length constrained to a specific range.
    ///
    /// This variant allows precise control over array length by specifying exact bounds.
    /// The `scaling` parameter controls how the length range interacts with the size parameter (1–100), following Hedgehog's Range model:
    ///
    /// - `.constant`: The full range is available at all sizes.
    /// - `.linear` (default): The upper bound grows linearly from the lower bound toward the specified upper bound as size increases.
    /// - `.exponential`: Same as linear but with exponential interpolation.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements.
    ///   - range: The allowed range for array length.
    ///   - scaling: The distribution strategy for the length. Defaults to `.linear`
    /// - Returns: A generator that produces arrays with length in the specified range.
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<[Output]> {
        let sequenceOperation = ReflectiveOperation.sequence(
            length: Gen.choose(in: range, scaling: scaling),
            gen: elementGenerator.erase()
        )
        return .impure(operation: sequenceOperation) { result in
            guard let array = result as? [Output] else {
                throw GeneratorError.typeMismatch(
                    expected: String(describing: type(of: [Output].self)),
                    actual: String(describing: type(of: result))
                )
            }
            return .pure(array)
        }
    }

    /// Creates a generator for an array with exactly the specified length.
    ///
    /// This is a convenience method that generates arrays of a fixed size, useful when you need predictable collection sizes for testing.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements.
    ///   - exactly: The exact length the array should have.
    /// - Returns: A generator that produces arrays of the specified length.
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        exactly: UInt64
    ) -> ReflectiveGenerator<[Output]> {
        arrayOf(elementGenerator, Gen.choose(in: exactly ... exactly))
    }

    /// Creates a generator for dictionaries with random key-value pairs.
    ///
    /// Generates a key array first, then binds on the key count to generate exactly the right number of values. Duplicate keys keep the first value.
    ///
    /// - Parameters:
    ///   - keyGenerator: Generator for dictionary keys (must be Hashable).
    ///   - valueGenerator: Generator for dictionary values.
    /// - Returns: A generator that produces dictionaries with random key-value pairs.
    /// - Note: Reflection decomposes the dictionary into key/value arrays via ``Dictionary/keys`` and ``Dictionary/values``. Iteration order is not preserved, so the reflected choice sequence may differ from the generation sequence. This does not affect correctness but may reduce shrinking quality.
    static func dictionaryOf<KeyOutput: Hashable, ValueOutput>(
        _ keyGenerator: ReflectiveGenerator<KeyOutput>,
        _ valueGenerator: ReflectiveGenerator<ValueOutput>
    ) -> ReflectiveGenerator<[KeyOutput: ValueOutput]> {
        let pairGen = Gen.arrayOf(keyGenerator)._bound(
            forward: { keys in
                Gen.contramap(
                    { (pair: ([KeyOutput], [ValueOutput])) in pair.1 },
                    Gen.arrayOf(valueGenerator, exactly: UInt64(keys.count))
                        ._map { values in (keys, values) }
                )
            },
            backward: { (pair: ([KeyOutput], [ValueOutput])) in pair.0 }
        )

        return Gen.contramap(
            { (dict: [KeyOutput: ValueOutput]) in (Array(dict.keys), Array(dict.values)) },
            pairGen._map { keys, values in
                Dictionary(
                    Swift.zip(keys, values).map { ($0, $1) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        )
    }

    /// Creates a generator for a set of random values.
    ///
    /// Generates an array and converts it to a set. Duplicate elements are collapsed, so the resulting set may be smaller than the requested length.
    ///
    /// - Parameters:
    ///   - elementGenerator: A generator for the elements of the set (must be Hashable).
    ///   - length: Optional generator for the set size. Defaults to size-based length.
    /// - Returns: A generator that produces a set of unique elements.
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        _ length: ReflectiveGenerator<UInt64>? = nil
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, length)._map { Set($0) }
    }

    /// Creates a generator for a set with size constrained to a specific range.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable).
    ///   - range: The allowed range for set size.
    ///   - scaling: The distribution strategy for the set size. Defaults to `.linear`
    /// - Returns: A generator that produces sets with size in the specified range.
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, within: range, scaling: scaling)._map { Set($0) }
    }

    /// Creates a generator for a set with exactly the specified number of elements.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable).
    ///   - exactly: The exact number of elements the set should have.
    /// - Returns: A generator that produces sets of the specified size.
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        exactly: UInt64
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, exactly: exactly)._map { Set($0) }
    }

    /// Shuffles the output of an array generator into a random permutation.
    ///
    /// Uses a sort-key approach: generates one random `UInt64` per element, then sorts the array by those keys. This produces a uniform permutation and reduces cleanly toward the original generation order (identity permutation) as the reducer drives sort keys toward zero. Identical keys preserve relative order (stable sort), so partial reduction is well-behaved.
    ///
    /// - Parameter gen: An array generator whose output should be shuffled.
    /// - Returns: A generator that produces a randomly permuted array.
    static func shuffled<Element>(
        _ gen: ReflectiveGenerator<some Collection<Element>>
    ) -> ReflectiveGenerator<[Element]> {
        gen._bind { array in
            guard array.count > 1 else { return .pure(Array(array)) }
            return Gen.arrayOf(
                Gen.choose(in: UInt64.min ... UInt64.max),
                exactly: UInt64(array.count)
            )
            ._map { keys in
                Swift.zip(array, keys)
                    .sorted { $0.1 < $1.1 }
                    .map(\.0)
            }
        }
    }

    /// Creates an array generator whose length is controlled by the current size parameter.
    ///
    /// This is a convenience method that combines `getSize` with `arrayOf` to create arrays that grow in complexity as tests progress. The size parameter acts as an upper bound, with the actual length chosen randomly within the constraint.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements.
    ///   - lengthRange: Optional range to constrain the array length. If nil, uses 0...size.
    /// - Returns: A generator that produces arrays with size-controlled length.
    static func sized<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        lengthRange: ClosedRange<UInt64>? = nil
    ) -> ReflectiveGenerator<[Output]> {
        getSize { size in
            let actualRange = lengthRange ?? (0 ... size)
            let clampedMin = max(actualRange.lowerBound, 0)
            let clampedMax = min(actualRange.upperBound, size)
            let finalRange = clampedMin ... clampedMax

            return arrayOf(elementGenerator, chooseDerived(in: finalRange))
        }
    }

    /// Generates a contiguous non-empty subrange of the given collection.
    ///
    /// Uses a bidirectional bind: the start position is generated first, then the length is bound to `1 ... (count - startPosition)`, guaranteeing validity by construction without rejection sampling. The backward pass extracts the start position from the subsequence's `startIndex` for reflection.
    ///
    /// Reduction drives the start position toward zero and the length toward one.
    static func slice<AnyCollection: Collection>(
        of collection: AnyCollection
    ) -> ReflectiveGenerator<AnyCollection.SubSequence> {
        let count = collection.count
        guard count > 0 else {
            return .pure(collection[collection.startIndex ..< collection.startIndex])
        }
        let indices = ContiguousArray(collection.indices)

        return Gen.chooseDerived(in: Int(0) ... (count - 1))
            ._bound(
                forward: { startPosition in
                    let maxLength = count - startPosition
                    return Gen.contramap(
                        { (subset: AnyCollection.SubSequence) -> Int in subset.count },
                        Gen.chooseDerived(in: Int(1) ... maxLength)
                            ._map { length -> AnyCollection.SubSequence in
                                let startIndex = indices[startPosition]
                                let endIndexPos = min(startPosition + length, indices.count)
                                let endIndex = endIndexPos < indices.count
                                    ? indices[endIndexPos]
                                    : collection.endIndex
                                return collection[startIndex ..< endIndex]
                            }
                    )
                },
                backward: { (subset: AnyCollection.SubSequence) -> Int in
                    indices.firstIndex(of: subset.startIndex) ?? 0
                }
            )
    }

    /// Creates a generator for a contiguous subrange of a generated collection.
    ///
    /// Composes the input generator with ``slice(of:)`` via `bind`, producing the collection's `SubSequence` type. Reduction comes for free: ``slice(of:)`` already reduces toward shorter subranges and earlier start positions, and the inner generator reduces its elements independently.
    ///
    /// - Parameter gen: A generator that produces a collection.
    /// - Returns: A generator that produces a contiguous subrange of the generated collection.
    static func slice<C: Collection>(
        of gen: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<C.SubSequence> {
        gen._bind { collection in
            slice(of: collection)
        }
    }

    /// Creates a generator that picks a random element from a collection.
    ///
    /// Reflection uses hash-based O(1) lookup to find the element's index.
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where C.Element: Hashable {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)
        var indexMap: [C.Element: Int] = [:]
        indexMap.reserveCapacity(elements.count)
        for (offset, element) in elements.enumerated() where indexMap[element] == nil {
            indexMap[element] = offset
        }

        return Gen.contramap(
            { (element: C.Element) -> Int in indexMap[element] ?? 0 },
            Gen.choose(in: 0 ... (elements.count - 1))._map { elements[$0] }
        )
    }

    /// Creates a generator that picks a random element from a collection.
    ///
    /// Reflection uses linear equality scan to find the element's index.
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> ReflectiveGenerator<C.Element> where C.Element: Equatable {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)

        return Gen.contramap(
            { (element: C.Element) -> Int in elements.firstIndex(of: element) ?? 0 },
            Gen.choose(in: 0 ... (elements.count - 1))._map { elements[$0] }
        )
    }

    /// Creates a generator that picks a random element from a collection, identified by a hashable partial path for O(1) reflection.
    ///
    /// Use this overload when elements are not ``Hashable`` themselves but have a hashable property that uniquely identifies them.
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A partial path to a hashable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection, Key: Hashable>(
        from collection: C,
        id path: some PartialPath<C.Element, Key>
    ) -> ReflectiveGenerator<C.Element> {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)
        var indexMap: [Key: Int] = [:]
        indexMap.reserveCapacity(elements.count)
        for (offset, element) in elements.enumerated() {
            guard let key = try? path.extract(from: element) else { continue }
            if indexMap[key] == nil {
                indexMap[key] = offset
            }
        }

        return Gen.contramap(
            { (element: C.Element) -> Int in
                guard let key = try? path.extract(from: element) else { return 0 }
                return indexMap[key] ?? 0
            },
            Gen.choose(in: 0 ... (elements.count - 1))._map { elements[$0] }
        )
    }

    /// Creates a generator that picks a random element from a collection, identified by an equatable partial path for reflection.
    ///
    /// Use this overload when elements are not ``Equatable`` but have an equatable property that uniquely identifies them. Prefer the ``Hashable`` overload when the key conforms to ``Hashable`` for O(1) lookup.
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A partial path to an equatable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection, Key: Equatable>(
        from collection: C,
        id path: some PartialPath<C.Element, Key>
    ) -> ReflectiveGenerator<C.Element> {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)

        return Gen.contramap(
            { (element: C.Element) -> Int in
                guard let key = try? path.extract(from: element) else { return 0 }
                return elements.firstIndex { (try? path.extract(from: $0)) == key } ?? 0
            },
            Gen.choose(in: 0 ... (elements.count - 1))._map { elements[$0] }
        )
    }

}
