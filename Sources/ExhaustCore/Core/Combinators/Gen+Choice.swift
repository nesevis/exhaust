#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Operations for making choices and generating random values within ranges.
/// These combinators handle weighted selection and bounded value generation.
package extension Gen {
    /// Selects from multiple weighted generator options by random draw.
    ///
    /// Weights are relative frequencies — they do not need to sum to any particular value. During reduction, earlier choices in the array and lower-weighted branches are tried first.
    ///
    /// - Parameter choices: An array of (weight, generator) pairs. Must not be empty.
    /// - Returns: A generator that produces values from one of the provided generators.
    /// - Precondition: At least one choice must be provided.
    static func pick<Output>(
        choices: [(weight: UInt64, generator: Generator<Output>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Generator<Output> {
        precondition(choices.isEmpty == false, "At least one choice must be provided")
        precondition(choices.allSatisfy { $0.weight > 0 }, "Weights must be greater than zero")
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call ensures the final monad has the correct `Output` type.
        let fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)

        var array = ContiguousArray<ReflectiveOperation.PickTuple>()
        array.reserveCapacity(choices.count)
        for index in choices.indices {
            let choice = choices[index]
            array.append(.init(
                fingerprint: fingerprint,
                id: UInt64(index),
                weight: choice.weight,
                generator: choice.generator.erase()
            ))
        }
        return liftF(.pick(choices: array))
    }

    /// Selects from multiple weighted generator options.
    ///
    /// Accepts `Int` weights so callers can use integer literals without explicit `UInt64` annotation. Delegates to the `UInt64` overload after conversion.
    ///
    /// - Parameter choices: An array of (weight, generator) pairs. Must not be empty.
    /// - Returns: A generator that produces values from one of the provided generators.
    /// - Precondition: At least one choice must be provided.
    static func pick<Output>(
        choices: [(weight: Int, generator: Generator<Output>)],
        fileID: StaticString = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> Generator<Output> {
        precondition(
            choices.map(\.weight).allSatisfy { $0 > 0 },
            "Weights must be higher than zero"
        )

        return pick(
            choices: choices.map { (UInt64($0.weight), $0.generator) },
            fileID: fileID,
            line: line,
            column: column
        )
    }

    /// Generates a random value within a range for any ``BitPatternConvertible`` type.
    ///
    /// When no range is provided, the full domain of the type is used. The range is marked as explicit so the reducer treats it as a hard bound that must not be narrowed.
    ///
    /// - Parameters:
    ///   - range: The range of values to generate from. Defaults to the type's full range.
    ///   - type: The output type to generate. Usually inferred from context.
    /// - Returns: A generator that produces random values of the specified type within the range.
    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>? = nil,
        type _: Output.Type = Output.self
    ) -> Generator<Output> {
        let isRangeExplicit = range != nil
        return choose(
            in: range,
            type: Output.self,
            isRangeExplicit: isRangeExplicit
        )
    }

    /// Generates a random element from a collection whose elements are ``Equatable``.
    ///
    /// Reflection uses equality-based index lookup. Round-robin indexing on the generated index prevents out-of-bounds failures when the reducer narrows the index range.
    static func choose<C: Collection>(
        from collection: C
    ) -> Generator<C.Element> where C.Element: Equatable, C.Index == Int {
        precondition(
            collection.isEmpty == false,
            "Cannot choose from an empty collection"
        )
        // Use Gen.contramap directly rather than .mapped because the backward closure throws and .mapped propagates that via rethrows (from FreerMonad.bind), which would force this function to be marked throws — even though the throw only happens at reflection time, never during construction.
        let count = collection.count
        return Gen.contramap(
            { (element: C.Element) throws -> Int in
                guard let index = collection.firstIndex(of: element) else {
                    throw ReflectionError
                        .couldNotReflectOnSequenceElement(
                            "Collection does not contain \(element)"
                        )
                }
                return index
            },
            Gen.choose(in: collection.startIndex ... collection.endIndex.advanced(by: -1))
                // We're using round-robin indexing here so that the lookup does not fail when reducing
                .map { collection[$0 % count] }
        )
    }

    /// Generates a random element from a collection without requiring ``Equatable`` conformance.
    ///
    /// Forward-only: reflection is not supported because there is no way to find the element's index without equality comparison.
    static func choose<C: Collection>(
        from collection: C
    ) -> Generator<C.Element> where C.Index == Int {
        precondition(
            collection.isEmpty == false,
            "Cannot choose from an empty collection"
        )
        let count = collection.count
        return Gen.choose(in: collection.startIndex ... collection.endIndex.advanced(by: -1))
            // We're using round-robin indexing here so that the lookup does not fail when reducing
            .map { collection[$0 % count] }
    }

    /// Internal helper for choose ranges derived from runtime context (for example ``getSize``).
    ///
    /// These ranges should not be treated as strict during reflection because the contextual value that produced them may be opaque from the reflected output.
    static func chooseDerived<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>,
        type _: Output.Type = Output.self
    ) -> Generator<Output> {
        choose(
            in: range,
            type: Output.self,
            isRangeExplicit: false
        )
    }

    /// Generates a random value within a range, using a ``SizeScaling`` distribution to control how tightly values cluster around an origin at small sizes.
    ///
    /// The scaling strategy is erased to ``ChooseBitsScaling`` and attached directly to the emitted ``ReflectiveOperation/chooseBits(min:max:tag:isRangeExplicit:scaling:)`` operation. Generation interpreters consult the active generation size at sample time and narrow the effective sampling range relative to `range`. Reflection, analysis, and the reducer observe the declared range unchanged.
    ///
    /// - Parameters:
    ///   - range: The full range of values to generate from at size 100.
    ///   - scaling: The distribution strategy controlling how the range expands.
    /// - Returns: A generator that produces size-scaled random values.
    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>,
        scaling: SizeScaling<Output>
    ) -> Generator<Output> {
        choose(
            in: range,
            type: Output.self,
            isRangeExplicit: true,
            scaling: scaling.erased
        )
    }

    /// Computes the effective sampling range for a size-scaled chooseBits operation.
    ///
    /// Generation interpreters call this at sample time with the tag's declared bit-pattern range and the current size. The origin is resolved from the scaling (explicit `originBits` if present, otherwise ``TypeTag/simplestBitPattern``) and clamped into `min...max`.
    ///
    /// For floating-point tags, scaling operates in numeric space so that a fraction of 0.1 on `0.0...10000.0` produces `0.0...1000.0`, not a sliver of subnormals. For integer tags, scaling operates in bit-pattern space as before.
    @inline(__always)
    static func applyScaling(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        scaling: ChooseBitsScaling,
        size: UInt64
    ) -> ClosedRange<UInt64> {
        let fraction = Swift.min(Double(size) / 100.0, 1.0)
        guard fraction < 1.0 else { return min ... max }

        let origin: UInt64?
        let isExponential: Bool
        switch scaling {
        case let .linear(o):
            origin = o
            isExponential = false
        case let .exponential(o):
            origin = o
            isExponential = true
        }

        if tag.isFloatingPoint {
            return applyFloatingPointScaling(
                min: min, max: max, tag: tag,
                originBits: origin, fraction: fraction,
                isExponential: isExponential
            )
        }

        let originBits = Swift.min(Swift.max(origin ?? tag.simplestBitPattern, min), max)
        let lowerDistance = scaledDistance(
            originBits - min,
            fraction: fraction,
            isExponential: isExponential
        )
        let upperDistance = scaledDistance(
            max - originBits,
            fraction: fraction,
            isExponential: isExponential
        )
        return (originBits - lowerDistance) ... (originBits + upperDistance)
    }

    /// Floating-point scaling that operates in numeric space rather than bit-pattern space.
    ///
    /// This avoids the problem where bit-pattern-space scaling concentrates the effective range in subnormals, because the bit-pattern distance between 0.0 and 1e-300 is nearly the same as between 1e-300 and 1e+308.
    private static func applyFloatingPointScaling(
        min: UInt64,
        max: UInt64,
        tag: TypeTag,
        originBits: UInt64?,
        fraction: Double,
        isExponential: Bool
    ) -> ClosedRange<UInt64> {
        var numericMin = tag.numericDoubleValue(forBitPattern: min)
        var numericMax = tag.numericDoubleValue(forBitPattern: max)
        if numericMin.isNaN || numericMin.isInfinite { numericMin = -Double.greatestFiniteMagnitude }
        if numericMax.isNaN || numericMax.isInfinite { numericMax = Double.greatestFiniteMagnitude }
        let resolvedOriginBits = Swift.min(Swift.max(originBits ?? tag.simplestBitPattern, min), max)
        let numericOrigin = tag.numericDoubleValue(forBitPattern: resolvedOriginBits)

        let lowerSpan = numericOrigin - numericMin
        let upperSpan = numericMax - numericOrigin

        let scaledLower: Double
        let scaledUpper: Double
        if isExponential {
            scaledLower = lowerSpan > 0 ? Swift.min(pow(lowerSpan, fraction), lowerSpan) : 0
            scaledUpper = upperSpan > 0 ? Swift.min(pow(upperSpan, fraction), upperSpan) : 0
        } else {
            scaledLower = lowerSpan * fraction
            scaledUpper = upperSpan * fraction
        }

        let effectiveLower = numericOrigin - scaledLower
        let effectiveUpper = numericOrigin + scaledUpper
        return tag.floatingBitPattern(from: effectiveLower) ... tag.floatingBitPattern(from: effectiveUpper)
    }

    /// Computes the effective range for a given size by interpolating from the origin toward the bounds using the specified scaling strategy.
    ///
    /// Bare `.linear` and `.exponential` anchor at the type's semantically simplest value (zero for signed and floating-point types; the lower bound for unsigned types), clamped to the given range via ``TypeTag/simplestBitPattern``. This keeps distributions centered on the natural zero even though scaling is performed in bit-pattern space, and it avoids ``ChoiceValue`` construction on the materialization hot path.
    static func scaledRange<Output: BitPatternConvertible>(
        _ range: ClosedRange<Output>,
        scaling: SizeScaling<Output>,
        size: UInt64
    ) -> ClosedRange<Output> {
        let fraction = min(Double(size) / 100.0, 1.0)
        guard fraction < 1.0 else { return range }

        let lowerBits = range.lowerBound.bitPattern64
        let upperBits = range.upperBound.bitPattern64

        let originBits: UInt64
        let isExponential: Bool

        switch scaling {
        case .constant:
            return range
        case .linear:
            originBits = min(max(Output.tag.simplestBitPattern, lowerBits), upperBits)
            isExponential = false
        case let .linearFrom(origin):
            originBits = min(max(origin.bitPattern64, lowerBits), upperBits)
            isExponential = false
        case .exponential:
            originBits = min(max(Output.tag.simplestBitPattern, lowerBits), upperBits)
            isExponential = true
        case let .exponentialFrom(origin):
            originBits = min(max(origin.bitPattern64, lowerBits), upperBits)
            isExponential = true
        }

        let lowerDistance = scaledDistance(
            originBits - lowerBits,
            fraction: fraction,
            isExponential: isExponential
        )
        let upperDistance = scaledDistance(
            upperBits - originBits,
            fraction: fraction,
            isExponential: isExponential
        )
        let effectiveLower = originBits - lowerDistance
        let effectiveUpper = originBits + upperDistance

        return Output(bitPattern64: effectiveLower) ... Output(bitPattern64: effectiveUpper)
    }

    /// Scales a distance from origin to bound by the given fraction (0–1).
    ///
    /// Follows Hedgehog's scaling approach in real-valued arithmetic: linear is `(distance + 1) · fraction`, exponential is `(distance + 1)^fraction - 1`. The `+1` ensures non-trivial ranges at small sizes.
    ///
    /// - Note: Arithmetic is performed in ``Double`` to avoid overflow when `distance` is close to `UInt64.max / size`. Integer multiplication would wrap silently and collapse the effective range to zero at inconvenient sizes.
    static func scaledDistance(
        _ distance: UInt64,
        fraction: Double,
        isExponential: Bool
    ) -> UInt64 {
        guard distance > 0, fraction > 0 else { return 0 }

        let base = distance == .max ? Double(distance) : Double(distance) + 1.0
        let scaled = isExponential
            ? pow(base, fraction) - 1.0
            : base * fraction
        guard scaled > 0 else { return 0 }
        if scaled >= Double(distance) { return distance }
        return UInt64(scaled.rounded())
    }

    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>? = nil,
        type _: Output.Type = Output.self,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling? = nil
    ) -> Generator<Output> {
        let minBits = range?.lowerBound.bitPattern64 ?? Output.bitPatternRange.lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? Output.bitPatternRange.upperBound

        let operation = ReflectiveOperation.chooseBits(
            min: minBits,
            max: maxBits,
            tag: Output.tag,
            isRangeExplicit: isRangeExplicit,
            scaling: scaling
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                throw GeneratorError.typeMismatch(
                    expected: "any BitPatternConvertible",
                    actual: String(describing: Swift.type(of: result))
                )
            }
            return .pure(Output(bitPattern64: convertible.bitPattern64))
        }
    }

    /// Generates a raw ``UInt64`` value within a bit range, tagged as ``.bits``.
    ///
    /// Use this for composite generators (UUID, Int128, UInt128) where the individual UInt64 halves are not semantically meaningful on their own.
    /// Boundary analysis will produce only all-low / all-high values.
    static func chooseBits(
        in range: ClosedRange<UInt64>? = nil
    ) -> Generator<UInt64> {
        let resolvedRange = range ?? UInt64.min ... .max
        let operation = ReflectiveOperation.chooseBits(
            min: resolvedRange.lowerBound,
            max: resolvedRange.upperBound,
            tag: .bits,
            isRangeExplicit: range != nil
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                throw GeneratorError.typeMismatch(
                    expected: "any BitPatternConvertible",
                    actual: String(describing: Swift.type(of: result))
                )
            }
            return .pure(UInt64(bitPattern64: convertible.bitPattern64))
        }
    }
}
