/// Operations for generating collections like arrays and dictionaries.
/// These combinators handle the complexities of generating structured data with proper shrinking behavior.
public extension Gen {
    /// Creates a generator for an array of random values.
    ///
    /// This implementation is stack-safe and can generate very large arrays without overflowing.
    /// It works by first generating a random length, then using a primitive `.sequence` operation
    /// which the interpreter can execute iteratively.
    ///
    /// The array length is controlled by the provided length generator, which defaults to a
    /// size-based range if not specified.
    ///
    /// - Parameters:
    ///   - elementGenerator: A self-contained generator for the elements of the array
    ///   - length: Optional generator for the array length. Defaults to size-based length
    /// - Returns: A generator that produces an array of elements
    @inlinable
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        _ length: ReflectiveGenerator<UInt64>? = nil,
    ) -> ReflectiveGenerator<[Output]> {
        // Use `bind` to get the result of the length generator.
        let sequenceOperation = ReflectiveOperation.sequence(
            length: length ?? Gen.getSize().bind {
                Gen.chooseDerived(in: ($0 / 10) ... $0)
            },
            gen: elementGenerator.erase(),
        )
        // Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOperation) { result in
            guard let array = result as? [Output] else {
                throw GeneratorError.typeMismatch(
                    expected: String(describing: type(of: [Output].self)),
                    actual: String(describing: type(of: result)),
                )
            }
            return .pure(array)
        }
    }

    /// Creates a generator for an array with length constrained to a specific range.
    ///
    /// This variant allows precise control over array length by specifying exact bounds.
    /// The `scaling` parameter controls how the length range interacts with the size
    /// parameter (1–100), following Hedgehog's Range model:
    ///
    /// - `.constant`: The full range is available at all sizes.
    /// - `.linear` (default): The upper bound grows linearly from the lower bound toward
    ///   the specified upper bound as size increases.
    /// - `.exponential`: Same as linear but with exponential interpolation.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements
    ///   - range: The allowed range for array length
    ///   - scaling: The distribution strategy for the length. Defaults to `.linear`
    /// - Returns: A generator that produces arrays with length in the specified range
    @inlinable
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear,
    ) -> ReflectiveGenerator<[Output]> {
        let sequenceOperation = ReflectiveOperation.sequence(
            length: Gen.choose(in: range, scaling: scaling),
            gen: elementGenerator.erase(),
        )
        // Lift the operation. The continuation will decode the `[Any]` result.
        return .impure(operation: sequenceOperation) { result in
            let array = result as! [Output]
            return .pure(array)
        }
    }

    /// Creates a generator for an array with exactly the specified length.
    ///
    /// This is a convenience method that generates arrays of a fixed size,
    /// useful when you need predictable collection sizes for testing.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements
    ///   - exactly: The exact length the array should have
    /// - Returns: A generator that produces arrays of the specified length
    @inlinable
    static func arrayOf<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        exactly: UInt64,
    ) -> ReflectiveGenerator<[Output]> {
        arrayOf(elementGenerator, Gen.choose(in: exactly ... exactly))
    }

    /// Creates a generator for dictionaries with random key-value pairs.
    ///
    /// This combinator generates dictionaries by creating parallel arrays of keys and values,
    /// then zipping them together. If duplicate keys are generated, the `uniquingKeysWith`
    /// parameter determines which value to keep (currently keeps the first value).
    ///
    /// The dictionary size follows the same size-based generation as arrays, ensuring
    /// consistent behavior across collection types.
    ///
    /// - Parameters:
    ///   - keyGenerator: Generator for dictionary keys (must be Hashable)
    ///   - valueGenerator: Generator for dictionary values
    /// - Returns: A generator that produces dictionaries with random key-value pairs
    @inlinable
    static func dictionaryOf<KeyOutput: Hashable, ValueOutput>(
        _ keyGenerator: ReflectiveGenerator<KeyOutput>,
        _ valueGenerator: ReflectiveGenerator<ValueOutput>,
    ) -> ReflectiveGenerator<[KeyOutput: ValueOutput]> {
        Gen.zip(
            // These arrays use `getSize()` under the hood and will be the same length
            Gen.arrayOf(keyGenerator),
            Gen.arrayOf(valueGenerator),
        )
        .mapped(
            forward: {
                Dictionary(
                    Swift.zip($0.0, $0.1).map { ($0.0, $0.1) },
                    uniquingKeysWith: { key, _ in key },
                )
            },
            // This will be out of order, but is that ok?
            backward: { (Array($0.keys), Array($0.values)) },
        )
    }

    /// Creates a generator for a set of unique random values.
    ///
    /// This implementation generates an array of elements, filters out any with duplicates,
    /// and converts to a set. The filter operation ensures deterministic reproducibility
    /// through seeds while leveraging CGS optimization to minimize wasted generation cycles.
    ///
    /// - Parameters:
    ///   - elementGenerator: A generator for the elements of the set (must be Hashable)
    ///   - length: Optional generator for the set size. Defaults to size-based length
    /// - Returns: A generator that produces a set of unique elements
    @inlinable
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        _ length: ReflectiveGenerator<UInt64>? = nil,
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, length)
            .filter { Set($0).count == $0.count }
            .mapped(
                forward: { Set($0) },
                backward: { Array($0) }
            )
    }

    /// Creates a generator for a set with size constrained to a specific range.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable)
    ///   - range: The allowed range for set size
    ///   - scaling: The distribution strategy for the set size. Defaults to `.linear`
    /// - Returns: A generator that produces sets with size in the specified range
    @inlinable
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        within range: ClosedRange<UInt64>,
        scaling: SizeScaling<UInt64> = .linear,
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, within: range, scaling: scaling)
            .filter { Set($0).count == $0.count }
            .mapped(
                forward: { Set($0) },
                backward: { Array($0) }
            )
    }

    /// Creates a generator for a set with exactly the specified number of elements.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for set elements (must be Hashable)
    ///   - exactly: The exact number of elements the set should have
    /// - Returns: A generator that produces sets of the specified size
    @inlinable
    static func setOf<Element: Hashable>(
        _ elementGenerator: ReflectiveGenerator<Element>,
        exactly: UInt64,
    ) -> ReflectiveGenerator<Set<Element>> {
        arrayOf(elementGenerator, exactly: exactly)
            .filter { Set($0).count == $0.count }
            .mapped(
                forward: { Set($0) },
                backward: { Array($0) }
            )
    }

    /// Shuffles the output of an array generator into a random permutation.
    ///
    /// Uses a sort-key approach: generates one random `UInt64` per element, then
    /// sorts the array by those keys. This produces a uniform permutation and
    /// shrinks cleanly toward the original generation order (identity permutation)
    /// as the reducer drives sort keys toward zero. Identical keys preserve
    /// relative order (stable sort), so partial shrinking is well-behaved.
    ///
    /// - Parameter gen: An array generator whose output should be shuffled
    /// - Returns: A generator that produces a randomly permuted array
    @inlinable
    static func shuffle<Element, C: Collection>(
        _ gen: ReflectiveGenerator<C>,
    ) -> ReflectiveGenerator<[Element]> where C.Element == Element {
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

    /// Creates an array generator whose length is controlled by the current size parameter.
    ///
    /// This is a convenience method that combines `getSize` with `arrayOf` to create
    /// arrays that grow in complexity as tests progress. The size parameter acts as
    /// an upper bound, with the actual length chosen randomly within the constraint.
    ///
    /// - Parameters:
    ///   - elementGenerator: The generator for array elements
    ///   - lengthRange: Optional range to constrain the array length. If nil, uses 0...size
    /// - Returns: A generator that produces arrays with size-controlled length
    @inlinable
    static func sized<Output>(
        _ elementGenerator: ReflectiveGenerator<Output>,
        lengthRange: ClosedRange<UInt64>? = nil,
    ) -> ReflectiveGenerator<[Output]> {
        getSize().bind { size in
            let actualRange = lengthRange ?? (0 ... size)
            let clampedMin = max(actualRange.lowerBound, 0)
            let clampedMax = min(actualRange.upperBound, size)
            let finalRange = clampedMin ... clampedMax

            return arrayOf(elementGenerator, chooseDerived(in: finalRange))
        }
    }

    @inlinable
    static func subset<AnyCollection: Collection>(
        of collection: AnyCollection,
    ) -> ReflectiveGenerator<AnyCollection.SubSequence> {
        getSize().bind { size in
            let count = collection.count
            // Max length with size as percentage of total space/count
            let maxLength = min(((count * Int(size)) / 100) + 2, count)

            // Convert collection to array of indices for easier manipulation
            // Surely there's a better way? 😬
            let indices = ContiguousArray(collection.indices)
            guard !indices.isEmpty else {
                return .pure(collection[collection.startIndex ..< collection.startIndex])
            }

            return Gen.zip(
                Gen.chooseDerived(in: 1 ... maxLength), // subset length
                Gen.chooseDerived(in: 0 ... (count - 1)), // start position index
            )
            .filter { length, startIndexPos in
                startIndexPos + length <= count
            }
            .mapped(
                forward: { length, startIndexPos in
                    let startIndex = indices[startIndexPos]
                    let endIndexPos = min(startIndexPos + length, indices.count)
                    let endIndex = endIndexPos < indices.count ? indices[endIndexPos] : collection.endIndex
                    return collection[startIndex ..< endIndex]
                },
                backward: { subset in
                    // Find the position of start index in the indices array
                    let startPos = indices.firstIndex(of: subset.startIndex) ?? 0
                    return (subset.count, startPos)
                },
            )
        }
    }

    /// Creates a generator for a contiguous subrange of a generated collection.
    ///
    /// Composes the input generator with `subset(of:)` via `bind`, producing
    /// the collection's `SubSequence` type. Shrinking comes for free: `subset(of:)`
    /// already shrinks toward shorter subranges and earlier start positions, and
    /// the inner generator shrinks its elements independently.
    ///
    /// - Parameter gen: A generator that produces a collection
    /// - Returns: A generator that produces a contiguous subrange of the generated collection
    @inlinable
    static func sub<C: Collection>(
        _ gen: ReflectiveGenerator<C>
    ) -> ReflectiveGenerator<C.SubSequence> {
        gen.bind { collection in
            subset(of: collection)
        }
    }

    /// Creates a generator that picks a random element from a collection.
    ///
    /// This combinator generates individual elements by selecting random indices
    /// from the provided collection. It works with any ``Collection`` type.
    ///
    /// - Parameter collection: The collection to pick elements from
    /// - Returns: A generator that produces random elements from the collection
    @inlinable
    static func element<AnyCollection: Collection>(
        from collection: AnyCollection,
    ) -> ReflectiveGenerator<AnyCollection.Element> {
        precondition(collection.isEmpty == false, "Cannot return random element from empty collection")
        let count = collection.count
        let dict = Dictionary(grouping: collection.enumerated(), by: \.offset)
            .mapValues { $0[0].element }

        return Gen.choose(in: 0 ... (count - 1))
            .mapped(
                forward: { dict[$0]! },
                backward: { element in
                    // Find the first index where this element appears
                    // This is best-effort since elements might recur
                    if let element = element as? any Equatable {
                        if let (index, _) = dict.first(where: { element.isEqualToAny($0.value) }) {
                            return index
                        }
                    }
                    return 0
                },
            )
    }

    /// Creates a generator that picks a random element from a collection.
    ///
    /// This combinator generates individual elements by selecting random indices
    /// from the provided collection. It works with any ``Collection`` type.
    ///
    /// - Parameter collection: The collection to pick elements from
    /// - Returns: A generator that produces random elements from the collection
    @inlinable
    static func element<AnyCollection: Collection>(
        from collection: AnyCollection,
    ) -> ReflectiveGenerator<AnyCollection.Element> where AnyCollection.Element: Hashable {
        precondition(collection.isEmpty == false, "Cannot return random element from empty collection")
        let enumerated = collection.enumerated()
        let elementDict = Dictionary(grouping: enumerated, by: \.element)
            .mapValues { $0[0].offset }
        let intDict = Dictionary(grouping: enumerated, by: \.offset)
            .mapValues { $0[0].element }

        return Gen.choose(in: 0 ... (collection.count - 1))
            .mapped(
                forward: { intDict[$0]! },
                backward: { elementDict[$0]! },
            )
    }
}
