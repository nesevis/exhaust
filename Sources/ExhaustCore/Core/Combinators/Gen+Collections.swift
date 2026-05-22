// Operations for generating collections like arrays and dictionaries.
// These combinators handle the complexities of generating structured data with proper reduction behavior.

package extension Gen {
    /// Generates arrays whose length comes from an optional length generator.
    ///
    /// When `length` is nil, the array length scales with the size parameter (0...size). Pass an explicit length generator to decouple length from size — for example, a fixed-range ``choose(in:scaling:)`` or a ``just(_:)`` for a constant.
    ///
    /// - Note: Stack-safe for arbitrarily large arrays — the interpreter drives the element loop iteratively, not recursively.
    ///
    /// - Parameters:
    ///   - elementGenerator: A self-contained generator for the elements of the array.
    ///   - length: Optional generator for the array length. Defaults to size-based length.
    /// - Returns: A generator that produces an array of elements.
    static func arrayOf<Output>(
        _ elementGenerator: Generator<Output>,
        _ length: Generator<UInt64>? = nil
    ) -> Generator<[Output]> {
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

    /// Generates arrays with length constrained to explicit bounds.
    ///
    /// Use this overload when the length bounds should not scale with the size parameter's default range (0...size). The `scaling` parameter controls how the length range interacts with the size parameter (1-100), following Hedgehog's Range model:
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
        _ elementGenerator: Generator<Output>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> Generator<[Output]> {
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

    /// Generates arrays of exactly the specified length.
    ///
    /// Shorthand for `arrayOf(elementGenerator, within: exactly ... exactly)`. Use this when the array length is a fixed constant rather than a range.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements.
    ///   - exactly: The exact length the array should have.
    /// - Returns: A generator that produces arrays of the specified length.
    static func arrayOf<Output>(
        _ elementGenerator: Generator<Output>,
        exactly: UInt64
    ) -> Generator<[Output]> {
        arrayOf(elementGenerator, Gen.choose(in: exactly ... exactly))
    }

    /// Generates dictionaries with random key-value pairs.
    ///
    /// Produces a key array first, then generates exactly that many values via a dependent bind. Duplicate keys keep the first value.
    ///
    /// - Parameters:
    ///   - keyGenerator: Generator for dictionary keys (must be Hashable).
    ///   - valueGenerator: Generator for dictionary values.
    /// - Returns: A generator that produces dictionaries with random key-value pairs.
    /// - Note: Reflection decomposes the dictionary into key/value arrays via ``Dictionary/keys`` and ``Dictionary/values``. Iteration order is not preserved, so the reflected choice sequence may differ from the generation sequence. This does not affect correctness but may degrade reduction quality.
    static func dictionaryOf<KeyOutput: Hashable, ValueOutput>(
        _ keyGenerator: Generator<KeyOutput>,
        _ valueGenerator: Generator<ValueOutput>
    ) -> Generator<[KeyOutput: ValueOutput]> {
        let pairGen = Gen.arrayOf(keyGenerator)._bound(
            forward: { keys in
                Gen.contramap(
                    { (pair: ([KeyOutput], [ValueOutput])) in pair.1 },
                    Gen.arrayOf(valueGenerator, exactly: UInt64(keys.count))
                        .map { values in (keys, values) }
                )
            },
            backward: { (pair: ([KeyOutput], [ValueOutput])) in pair.0 }
        )

        return Gen.contramap(
            { (dict: [KeyOutput: ValueOutput]) in (Array(dict.keys), Array(dict.values)) },
            pairGen.map { keys, values in
                Dictionary(
                    Swift.zip(keys, values).map { ($0, $1) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        )
    }

    /// Generates sets of random values.
    ///
    /// Produces an array and converts it to a set. Duplicate elements are collapsed, so the resulting set may be smaller than the requested length.
    ///
    /// - Parameters:
    ///   - elementGenerator: A generator for the elements of the set (must be Hashable).
    ///   - length: Optional generator for the set size. Defaults to size-based length.
    /// - Returns: A generator that produces a set of unique elements.
    static func setOf<Element: Hashable>(
        _ elementGenerator: Generator<Element>,
        _ length: Generator<UInt64>? = nil
    ) -> Generator<Set<Element>> {
        arrayOf(elementGenerator, length).map { Set($0) }
    }

    /// Generates sets with size constrained to explicit bounds.
    ///
    /// Use this overload when the size bounds should not scale with the size parameter's default range. Duplicate elements are collapsed, so the resulting set may be smaller than the requested length.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable).
    ///   - range: The allowed range for set size.
    ///   - scaling: The distribution strategy for the set size. Defaults to `.linear`
    /// - Returns: A generator that produces sets with size in the specified range.
    static func setOf<Element: Hashable>(
        _ elementGenerator: Generator<Element>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear
    ) -> Generator<Set<Element>> {
        arrayOf(elementGenerator, within: range, scaling: scaling).map { Set($0) }
    }

    /// Generates sets of exactly the specified size.
    ///
    /// Shorthand for `setOf(elementGenerator, within: exactly ... exactly)`. Duplicate elements are collapsed, so the resulting set may be smaller than `exactly`.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable).
    ///   - exactly: The exact number of elements the set should have.
    /// - Returns: A generator that produces sets of the specified size.
    static func setOf<Element: Hashable>(
        _ elementGenerator: Generator<Element>,
        exactly: UInt64
    ) -> Generator<Set<Element>> {
        arrayOf(elementGenerator, exactly: exactly).map { Set($0) }
    }

    /// Produces a uniform random permutation of the array from an inner generator.
    ///
    /// Reduction drives sort keys toward zero, converging on the original generation order (identity permutation). Identical keys preserve relative order (stable sort), so partial reduction is well-behaved.
    ///
    /// - Parameter gen: An array generator whose output should be shuffled.
    /// - Returns: A generator that produces a randomly permuted array.
    static func shuffled<Element>(
        _ gen: Generator<some Collection<Element>>
    ) -> Generator<[Element]> {
        gen.bind { array in
            guard array.count > 1 else { return .pure(Array(array)) }
            return Gen.arrayOf(
                Gen.choose(in: UInt64.min ... UInt64.max),
                exactly: UInt64(array.count)
            )
            .map { keys in
                Swift.zip(array, keys)
                    .sorted { $0.1 < $1.1 }
                    .map(\.0)
            }
        }
    }

    /// Generates arrays whose length grows with the size parameter.
    ///
    /// Use this when array length should scale with test complexity. The size parameter acts as an upper bound, with the actual length chosen randomly within the constraint.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements.
    ///   - lengthRange: Optional range to constrain the array length. If nil, uses 0...size.
    /// - Returns: A generator that produces arrays with size-controlled length.
    static func sized<Output>(
        _ elementGenerator: Generator<Output>,
        lengthRange: ClosedRange<UInt64>? = nil
    ) -> Generator<[Output]> {
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
    ) -> Generator<AnyCollection.SubSequence> {
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
                            .map { length -> AnyCollection.SubSequence in
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

    /// Generates a contiguous subrange of a generated collection.
    ///
    /// Composes the input generator with ``slice(of:)`` via bind. Reduction comes for free: ``slice(of:)`` reduces toward shorter subranges and earlier start positions, and the inner generator reduces its elements independently.
    ///
    /// - Parameter gen: A generator that produces a collection.
    /// - Returns: A generator that produces a contiguous subrange of the generated collection.
    static func slice<C: Collection>(
        of gen: Generator<C>
    ) -> Generator<C.SubSequence> {
        gen.bind { collection in
            slice(of: collection)
        }
    }

    /// Picks a random element from a collection.
    ///
    /// Prefer this overload when elements conform to ``Hashable`` — reflection uses hash-based O(1) lookup to find the element's index.
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> Generator<C.Element> where C.Element: Hashable {
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
            { (element: C.Element) throws -> Int in
                guard let index = indexMap[element] else {
                    throw ReflectionError.couldNotReflectOnSequenceElement(
                        "element not found in collection during reflection"
                    )
                }
                return index
            },
            Gen.choose(in: 0 ... (elements.count - 1)).map { elements[$0] }
        )
    }

    /// Picks a random element from a collection whose elements are ``Equatable`` but not ``Hashable``.
    ///
    /// Reflection uses a linear equality scan (O(n)) to find the element's index. Prefer the ``Hashable`` overload when available for O(1) reflection.
    ///
    /// - Parameter collection: The collection to pick elements from.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C
    ) -> Generator<C.Element> where C.Element: Equatable {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)

        return Gen.contramap(
            { (element: C.Element) throws -> Int in
                guard let index = elements.firstIndex(of: element) else {
                    throw ReflectionError.couldNotReflectOnSequenceElement(
                        "element not found in collection during reflection"
                    )
                }
                return index
            },
            Gen.choose(in: 0 ... (elements.count - 1)).map { elements[$0] }
        )
    }

    /// Picks a random element from a collection, using a ``Hashable`` key path for O(1) reflection lookup.
    ///
    /// Use this overload when elements are not ``Hashable`` themselves but have a hashable property that uniquely identifies them.
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A key path to a hashable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection, Key: Hashable>(
        from collection: C,
        id path: KeyPath<C.Element, Key>
    ) -> Generator<C.Element> {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)
        var indexMap: [Key: Int] = [:]
        indexMap.reserveCapacity(elements.count)
        for (offset, element) in elements.enumerated() {
            let key = element[keyPath: path]
            if indexMap[key] == nil {
                indexMap[key] = offset
            }
        }

        return Gen.contramap(
            { (element: C.Element) throws -> Int in
                guard let index = indexMap[element[keyPath: path]] else {
                    throw ReflectionError.couldNotReflectOnSequenceElement(
                        "element key not found in collection during reflection"
                    )
                }
                return index
            },
            Gen.choose(in: 0 ... (elements.count - 1)).map { elements[$0] }
        )
    }

    /// Picks a random element from a collection, using an ``Equatable`` key path for linear-scan reflection.
    ///
    /// Use this overload when elements are not ``Equatable`` but have an equatable property that uniquely identifies them. Prefer the ``Hashable`` key-path overload when the key conforms to ``Hashable`` for O(1) lookup.
    ///
    /// - Parameters:
    ///   - collection: The collection to pick elements from.
    ///   - id: A key path to an equatable property used to identify elements during reflection.
    /// - Returns: A generator that produces random elements from the collection.
    static func element<C: Collection>(
        from collection: C,
        id path: KeyPath<C.Element, some Equatable>
    ) -> Generator<C.Element> {
        precondition(
            collection.isEmpty == false,
            "Cannot return random element from empty collection"
        )
        let elements = ContiguousArray(collection)

        return Gen.contramap(
            { (element: C.Element) throws -> Int in
                let key = element[keyPath: path]
                guard let index = elements.firstIndex(where: { $0[keyPath: path] == key }) else {
                    throw ReflectionError.couldNotReflectOnSequenceElement(
                        "element key not found in collection during reflection"
                    )
                }
                return index
            },
            Gen.choose(in: 0 ... (elements.count - 1)).map { elements[$0] }
        )
    }
}
