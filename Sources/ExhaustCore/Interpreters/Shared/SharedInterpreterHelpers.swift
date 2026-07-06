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

    // MARK: - Sequence Length

    /// The largest element count a generated sequence may request — `UInt16.max`, a realistic high end for an array length. A drawn length above this is treated as a misused (too-wide) length generator rather than a real request, since generating substantially more is intractable for a property-test inner loop.
    package static let maximumSequenceLength = Int(UInt16.max)

    /// Converts a drawn sequence length to an element count, throwing ``GeneratorError/sequenceLengthExceedsMaximum(length:maximum:)`` when it exceeds ``maximumSequenceLength``. Guards every sequence interpreter against the trapping `Int(UInt64)` conversion and against allocating or looping over an intractable length.
    @inline(__always)
    static func sequenceElementCount(_ length: UInt64) throws -> Int {
        guard length <= UInt64(maximumSequenceLength) else {
            throw GeneratorError.sequenceLengthExceedsMaximum(length: length, maximum: maximumSequenceLength)
        }
        return Int(length)
    }

    // MARK: - Per-Value Generation Deadline

    /// How long a single value may take to materialize before generation fails: 10 seconds. The per-sequence length cap cannot see composition — nested sequences multiply, so an array of arrays passes the cap at every level while requesting rows times columns elements. The deadline converts that hang (and any other intractably expensive value) into a failure with a diagnosis. Ten seconds is orders of magnitude above any tractable value; a full-cap sequence of scalars materializes in milliseconds.
    package static let perValueGenerationBudgetNanoseconds: UInt64 = 10_000_000_000

    /// Throws ``GeneratorError/generationDeadlineExceeded(seconds:)`` when the per-value deadline has passed. Checked on a sampled cadence — at sequence entry (element zero) and every 1024th element after — so the clock read stays off the per-element hot path while nested structures, which re-enter their element loops constantly, still hit the entry check. Skipped entirely when `deadlineNanoseconds` is zero (generation that is not deadline-bound, such as reducer replays).
    @inline(__always)
    static func checkGenerationDeadline(_ deadlineNanoseconds: UInt64, elementIndex: Int) throws {
        guard deadlineNanoseconds > 0, elementIndex & 1023 == 0 else { return }
        guard monotonicNanoseconds() > deadlineNanoseconds else { return }
        throw GeneratorError.generationDeadlineExceeded(
            seconds: Double(perValueGenerationBudgetNanoseconds) / 1_000_000_000
        )
    }

    // MARK: - Parameter-Free Generator Walk

    /// Returns whether a generator produces values without any choices (no chooseBits, pick, sequence, zip, or getSize operations). Walks through transparent wrappers (pure, just, contramap, prune, transform).
    static func isParameterFree(_ gen: AnyGenerator) -> Bool {
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
    static func buildParameterFreeSubTree(for gen: AnyGenerator) -> ChoiceTree? {
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
        continuation: @escaping (Any) throws -> AnyGenerator,
        context: GeneratorTuning.TuningContext,
        predicate: @escaping (Output) -> Bool
    ) -> (Any) -> Bool {
        { innerValue in
            do {
                let nextGen = try continuation(innerValue)
                let output = try ValueInterpreter<Any>.generate(
                    nextGen,
                    maxRuns: 1,
                    using: &context.rng
                ) as? Output
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
    /// - Returns: The pick choices, or `nil` if the range is too small to subdivide (four values or fewer).
    static func subdivideChooseBits(
        lower: UInt64,
        upper: UInt64,
        tag: TypeTag,
        isRangeExplicit: Bool,
        scaling: ChooseBitsScaling? = nil,
        makeFingerprint: () -> UInt64,
        innerContinuation: @escaping (Any) throws -> AnyGenerator = { .pure($0) }
    ) -> ContiguousArray<ReflectiveOperation.PickTuple>? {
        let rangeSize = (lower ... upper).saturatingCount
        guard rangeSize > 4 else { return nil }

        let subrangeCount = Swift.min(4, Int(Swift.min(rangeSize, UInt64(Int.max))))
        let subranges = (lower ... upper).split(into: subrangeCount)

        var choices = ContiguousArray<ReflectiveOperation.PickTuple>()
        choices.reserveCapacity(subranges.count)

        for (index, subrange) in subranges.enumerated() {
            let subGen: AnyGenerator = .impure(
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

        return choices
    }
}
