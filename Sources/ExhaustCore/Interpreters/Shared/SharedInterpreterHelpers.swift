//
//  SharedInterpreterHelpers.swift
//  Exhaust
//

/// Helpers shared across multiple interpreter implementations to avoid duplicated logic.
package enum SharedInterpreterHelpers {
    // MARK: - Size Consumption

    /// Reads the active generation size in precedence order: a one-shot `.resize` override, then the persistent `context.size` baseline, then the per-run scaled size cycle.
    @inline(__always)
    static func consumeSize(_ context: inout GenerationContext) -> UInt64 {
        if let override = context.sizeOverride {
            context.sizeOverride = nil
            return override
        }
        if context.size > 0 {
            return context.size
        }
        return GenerationContext.scaledSize(forRun: context.runs)
    }

    // MARK: - Parameter-Free Generator Walk

    /// Returns whether a generator produces values without any choices (no chooseBits, pick, sequence, zip, or getSize operations). Walks through transparent wrappers (pure, just, contramap, prune, transform).
    static func isParameterFree(_ gen: ReflectiveGenerator<Any>) -> Bool {
        switch gen {
        case .pure:
            true
        case let .impure(operation, _):
            switch operation {
            case .just:
                true
            case let .contramap(_, inner), let .prune(inner):
                isParameterFree(inner)
            case let .transform(_, inner):
                isParameterFree(inner)
            default:
                false
            }
        }
    }

    /// Builds a minimal subtree for a parameter-free generator, or `nil` if the generator contains choices. Walks through transparent wrappers, returning `.just` for terminals.
    static func buildParameterFreeSubTree(for gen: ReflectiveGenerator<Any>) -> ChoiceTree? {
        switch gen {
        case .pure:
            .just
        case let .impure(operation, _):
            switch operation {
            case .just:
                .just
            case let .contramap(_, next), let .prune(next):
                buildParameterFreeSubTree(for: next)
            case let .transform(_, inner):
                buildParameterFreeSubTree(for: inner)
            default:
                nil
            }
        }
    }

    // MARK: - Composed Predicate

    /// Builds a predicate over an inner generator's output by threading a value through a continuation and evaluating the result via ``ValueInterpreter``.
    ///
    /// Used by the tuning handlers (contramap, resize, prune, classify) to compose a fitness predicate that evaluates inner values in the context of the full downstream pipeline.
    static func composedPredicate<Output>(
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Output>,
        context: GeneratorTuning.TuningContext,
        predicate: @escaping (Output) -> Bool
    ) -> (Any) -> Bool {
        { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Output>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng
                )
                return output.map(predicate) ?? false
            } catch {
                return false
            }
        }
    }

    // MARK: - ChooseBits Subdivision

    /// Builds a synthesized pick over subranges of a `chooseBits` range, splitting it into up to four equal-sized buckets.
    ///
    /// Each subrange becomes a branch with its own `chooseBits` generator. The caller provides a fingerprint for each branch and chooses how to wire the continuation.
    ///
    /// - Returns: The pick choices and branch count, or `nil` if the range is too small to subdivide (four values or fewer).
    static func subdivideChooseBits(
        lower: UInt64,
        upper: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling? = nil,
        makeFingerprint: () -> UInt64,
        innerContinuation: @escaping (Any) throws -> ReflectiveGenerator<Any> = { .pure($0) }
    ) -> (choices: ContiguousArray<ReflectiveOperation.PickTuple>, branchCount: UInt64)? {
        let rangeSize = (lower ... upper).saturatingCount
        guard rangeSize > 4 else { return nil }

        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
        let subranges = (lower ... upper).split(into: subrangeCount)

        let branchCount = UInt64(subranges.count)

        var choices = ContiguousArray<ReflectiveOperation.PickTuple>()
        choices.reserveCapacity(subranges.count)

        for (index, subrange) in subranges.enumerated() {
            let subGen: ReflectiveGenerator<Any> = .impure(
                operation: .chooseBits(
                    min: subrange.lowerBound,
                    max: subrange.upperBound,
                    tag: tag,
                    isRangeExplicit: isRangeExplicit,
                    scaling: scaling
                ),
                continuation: innerContinuation
            )
            choices.append(ReflectiveOperation.PickTuple(
                fingerprint: makeFingerprint(),
                id: UInt64(index),
                weight: 1,
                generator: subGen
            ))
        }

        return (choices, branchCount)
    }
}
