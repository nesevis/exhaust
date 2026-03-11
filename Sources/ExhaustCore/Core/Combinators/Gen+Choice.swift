import Foundation

/// Operations for making choices and generating random values within ranges.
/// These combinators handle weighted selection and bounded value generation.
public extension Gen {
    /// Creates a generator that randomly selects from multiple weighted options.
    ///
    /// This combinator enables probabilistic generation where different outcomes have different likelihoods. The weights don't need to sum to any particular value - they're interpreted as relative frequencies.
    ///
    /// During shrinking, the system will try simpler choices first based on their position in the choices array and their weights.
    ///
    /// - Parameter choices: An array of (weight, generator) pairs. Must not be empty.
    /// - Returns: A generator that produces values from one of the provided generators
    /// - Precondition: At least one choice must be provided
    static func pick<Output>(
        choices: [(weight: UInt64, generator: ReflectiveGenerator<Output>)],
    ) -> ReflectiveGenerator<Output> {
        precondition(choices.isEmpty == false, "At least one choice must be provided")
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has the correct `Output` type.
        var prng = Xoshiro256()
        let siteID = prng.next()

        var array = ContiguousArray<ReflectiveOperation.PickTuple>()
        array.reserveCapacity(choices.count)

        for index in choices.indices {
            let choice = choices[index]
            array.append(.init(
                siteID: siteID,
                id: UInt64(index),
                weight: choice.weight,
                generator: choice.generator.erase(),
            ))
        }
        return liftF(.pick(choices: array))
    }

    /// Creates a generator that randomly selects from multiple weighted options.
    ///
    /// This combinator enables probabilistic generation where different outcomes have different likelihoods. The weights don't need to sum to any particular value - they're interpreted as relative frequencies.
    ///
    /// During shrinking, the system will try simpler choices first based on their position in the choices array and their weights.
    ///
    /// - Parameter choices: An array of (weight, generator) pairs. Must not be empty.
    /// - Returns: A generator that produces values from one of the provided generators
    /// - Precondition: At least one choice must be provided
    @inlinable
    static func pick<Output>(
        choices: [(weight: Int, generator: ReflectiveGenerator<Output>)],
    ) -> ReflectiveGenerator<Output> {
        precondition(choices.map(\.weight).allSatisfy { $0 > 0 }, "Weights must be higher than zero")

        return pick(choices: choices.map { (UInt64($0.weight), $0.generator) })
    }

    /// Generates a random value within a specified range for types conforming to BitPatternConvertible.
    ///
    /// This is the primary method for generating bounded random values. It works by converting the range bounds to bit patterns, generating a random bit pattern within those bounds, then converting back to the target type.
    ///
    /// The type parameter allows the compiler to infer the return type, while the range parameter controls the bounds. If no range is provided, the full range for the type is used.
    ///
    /// - Parameters:
    ///   - range: The range of values to generate from. Defaults to the type's full range
    ///   - type: The output type to generate. Usually inferred from context
    /// - Returns: A generator that produces random values of the specified type within the range
    @inlinable
    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>? = nil,
        type _: Output.Type = Output.self,
    ) -> ReflectiveGenerator<Output> {
        let isRangeExplicit = range != nil
        return choose(
            in: range,
            type: Output.self,
            isRangeExplicit: isRangeExplicit,
        )
    }

    /// Chooses a random element from a collection by generating a random index.
    @inlinable
    static func choose<C: Collection>(
        from collection: C,
    ) -> ReflectiveGenerator<C.Element> where C.Element: Equatable, C.Index == Int {
        // Use Gen.contramap directly rather than .mapped because the backward
        // closure throws and .mapped propagates that via rethrows (from FreerMonad.bind),
        // which would force this function to be marked throws — even though the throw
        // only happens at reflection time, never during construction.
        let count = collection.count
        return Gen.contramap(
            { (element: C.Element) throws -> Int in
                guard let index = collection.firstIndex(of: element) else {
                    throw Interpreters.ReflectionError.couldNotReflectOnSequenceElement("Collection does not contain \(element)")
                }
                return index
            },
            Gen.choose(in: collection.startIndex ... collection.endIndex.advanced(by: -1))
                // We're using round-robin indexing here so that the lookup does not fail when shrinking
                ._map { collection[$0 % count] },
        )
    }

    /// Chooses a random element from a collection by generating a random index.
    @inlinable
    static func choose<C: Collection>(
        from collection: C,
    ) -> ReflectiveGenerator<C.Element> where C.Index == Int {
        let count = collection.count
        return Gen.choose(in: collection.startIndex ... collection.endIndex.advanced(by: -1))
            // We're using round-robin indexing here so that the lookup does not fail when shrinking
            ._map { collection[$0 % count] }
    }

    /// Internal helper for choose ranges derived from runtime context (e.g. `getSize`).
    ///
    /// These ranges should not be treated as strict during reflection because the contextual value that produced them may be opaque from the reflected output.
    @inlinable
    public static func chooseDerived<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>,
        type _: Output.Type = Output.self,
    ) -> ReflectiveGenerator<Output> {
        choose(
            in: range,
            type: Output.self,
            isRangeExplicit: false,
        )
    }

    /// Generates a random value within a range, using a ``SizeScaling`` distribution to control how tightly values cluster around an origin at small sizes.
    ///
    /// For `.constant`, delegates directly to ``choose(in:type:)`` with no size interaction.
    /// For all other scalings, the effective range is computed from the current size (1–100) using either linear or exponential interpolation in bit-pattern space.
    ///
    /// - Parameters:
    ///   - range: The full range of values to generate from at size 100.
    ///   - scaling: The distribution strategy controlling how the range expands.
    /// - Returns: A generator that produces size-scaled random values.
    @inlinable
    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>,
        scaling: SizeScaling<Output>,
    ) -> ReflectiveGenerator<Output> {
        switch scaling {
        case .constant:
            Gen.choose(in: range)
        case .linear, .linearFrom, .exponential, .exponentialFrom:
            Gen.getSize()._bind { size in
                let effectiveRange = scaledRange(range, scaling: scaling, size: size)
                return Gen.chooseDerived(in: effectiveRange)
            }
        }
    }

    /// Computes the effective range for a given size by interpolating from the origin toward the bounds using the specified scaling strategy.
    static func scaledRange<Output: BitPatternConvertible>(
        _ range: ClosedRange<Output>,
        scaling: SizeScaling<Output>,
        size: UInt64,
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
            originBits = lowerBits
            isExponential = false
        case let .linearFrom(origin):
            originBits = min(max(origin.bitPattern64, lowerBits), upperBits)
            isExponential = false
        case .exponential:
            originBits = lowerBits
            isExponential = true
        case let .exponentialFrom(origin):
            originBits = min(max(origin.bitPattern64, lowerBits), upperBits)
            isExponential = true
        }

        let effectiveLower = originBits - scaledDistance(originBits - lowerBits, fraction: fraction, isExponential: isExponential)
        let effectiveUpper = originBits + scaledDistance(upperBits - originBits, fraction: fraction, isExponential: isExponential)

        return Output(bitPattern64: effectiveLower) ... Output(bitPattern64: effectiveUpper)
    }

    /// Scales a distance from origin to bound by the given fraction (0–1).
    static func scaledDistance(_ distance: UInt64, fraction: Double, isExponential: Bool) -> UInt64 {
        guard distance > 0, fraction > 0 else { return 0 }

        if isExponential {
            // pow(distance + 1, fraction) - 1, clamped to avoid overflow on UInt64 conversion
            let result = pow(Double(distance) + 1.0, fraction) - 1.0
            return min(UInt64(result), distance)
        } else {
            let result = Double(distance) * fraction
            return min(UInt64(result), distance)
        }
    }

    static func choose<Output: BitPatternConvertible>(
        in range: ClosedRange<Output>? = nil,
        type _: Output.Type = Output.self,
        isRangeExplicit: Bool,
    ) -> ReflectiveGenerator<Output> {
        let minBits = range?.lowerBound.bitPattern64 ?? Output.bitPatternRanges[0].lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? Output.bitPatternRanges[0].upperBound

        return .impure(operation: .chooseBits(min: minBits, max: maxBits, tag: Output.tag, isRangeExplicit: isRangeExplicit)) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                throw GeneratorError.typeMismatch(
                    expected: "any BitPatternConvertible",
                    actual: String(describing: Swift.type(of: result)),
                )
            }
            return .pure(Output(bitPattern64: convertible.bitPattern64))
        }
    }

    /// Generates a raw `UInt64` value within a bit range, tagged as `.bits`.
    ///
    /// Use this for composite generators (UUID, Int128, UInt128) where the individual UInt64 halves are not semantically meaningful on their own.
    /// Boundary analysis will produce only all-low / all-high values.
    static func chooseBits(
        in range: ClosedRange<UInt64>? = nil,
    ) -> ReflectiveGenerator<UInt64> {
        let resolvedRange = range ?? UInt64.min ... .max
        return .impure(operation: .chooseBits(min: resolvedRange.lowerBound, max: resolvedRange.upperBound, tag: .bits, isRangeExplicit: range != nil)) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                throw GeneratorError.typeMismatch(
                    expected: "any BitPatternConvertible",
                    actual: String(describing: Swift.type(of: result)),
                )
            }
            return .pure(UInt64(bitPattern64: convertible.bitPattern64))
        }
    }
}
