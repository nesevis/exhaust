/// Sets each target value to its semantic simplest form (zero for numerics), or to the
/// range's lower bound when zero falls outside an explicit valid range.
///
/// Two phases: first tries setting ALL values to simplest simultaneously (handles filter-coupled generators), then iterates individually. The 2-cell chain ZeroValue => BinarySearchToZero means that targets where ZeroValue succeeds can skip binary search entirely.
public struct ZeroValueEncoder: AdaptiveEncoder, ComposableEncoder {
    public let name: EncoderName = .zeroValue
    public let phase = ReductionPhase.valueMinimization

    public func estimatedCost(sequence: ChoiceSequence, bindIndex _: BindSpanIndex?) -> Int? {
        let t = ChoiceSequence.extractAllValueSpans(from: sequence).count
        guard t > 0 else { return nil }
        // 1 all-at-once probe + t individual probes, one per non-zero target.
        return 1 + t
    }

    // MARK: - State

    private enum ZeroValuePhase {
        case allAtOnce
        case individual
    }

    private var sequence = ChoiceSequence()
    private var filteredSpans: [(seqIdx: Int, target: ChoiceValue, validRange: ClosedRange<UInt64>?, isRangeExplicit: Bool)] = []
    private var zeroPhase = ZeroValuePhase.allAtOnce
    private var spanIndex = 0

    // MARK: - Dual conformance disambiguation

    public var convergenceRecords: [Int: ConvergedOrigin] { [:] }

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let spans = Self.extractFilteredSpans(from: sequence, in: positionRange)
        guard spans.isEmpty == false else { return nil }
        return 1 + spans.count
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) {
        let spans = Self.extractFilteredSpans(from: sequence, in: positionRange)
        start(sequence: sequence, targets: .spans(spans), convergedOrigins: context.convergedOrigins)
    }

    // MARK: - AdaptiveEncoder

    public mutating func start(sequence: ChoiceSequence, targets: TargetSet, convergedOrigins _: [Int: ConvergedOrigin]?) {
        self.sequence = sequence
        zeroPhase = .allAtOnce
        spanIndex = 0
        filteredSpans = []

        guard case let .spans(spans) = targets else { return }

        for span in spans {
            let seqIdx = span.range.lowerBound
            guard let v = sequence[seqIdx].value else { continue }
            let target = Self.simplestTarget(for: v)
            guard target != v.choice else { continue }
            filteredSpans.append((seqIdx: seqIdx, target: target, validRange: v.validRange, isRangeExplicit: v.isRangeExplicit))
        }
    }

    public mutating func nextProbe(lastAccepted: Bool) -> ChoiceSequence? {
        guard filteredSpans.isEmpty == false else { return nil }

        switch zeroPhase {
        case .allAtOnce:
            // Transition to individual regardless of acceptance.
            zeroPhase = .individual
            spanIndex = 0

            // Build the all-simplest candidate.
            var allSimplest = sequence
            for entry in filteredSpans {
                allSimplest[entry.seqIdx] = .value(.init(
                    choice: entry.target,
                    validRange: entry.validRange,
                    isRangeExplicit: entry.isRangeExplicit
                ))
            }
            return allSimplest

        case .individual:
            if lastAccepted, spanIndex == 0 {
                // All-at-once probe was accepted — update base sequence with all targets
                // so individual probes build on the zeroed state.
                for entry in filteredSpans {
                    sequence[entry.seqIdx] = .value(.init(
                        choice: entry.target,
                        validRange: entry.validRange,
                        isRangeExplicit: entry.isRangeExplicit
                    ))
                }
            } else if lastAccepted, spanIndex > 0 {
                // Update base sequence with the previously accepted value.
                let prev = filteredSpans[spanIndex - 1]
                sequence[prev.seqIdx] = .value(.init(
                    choice: prev.target,
                    validRange: prev.validRange,
                    isRangeExplicit: prev.isRangeExplicit
                ))
            }

            while spanIndex < filteredSpans.count {
                let entry = filteredSpans[spanIndex]
                spanIndex += 1

                // Re-check: if the all-at-once pass was accepted, the base sequence
                // was updated and this span may already be at the target.
                guard let v = sequence[entry.seqIdx].value, entry.target != v.choice else {
                    continue
                }

                var candidate = sequence
                candidate[entry.seqIdx] = .value(.init(
                    choice: entry.target,
                    validRange: entry.validRange,
                    isRangeExplicit: entry.isRangeExplicit
                ))
                return candidate
            }
            return nil
        }
    }

    /// Returns the simplest valid target for a value.
    ///
    /// Stale-range escape hatch (matches legacy reduceIntegralValues): when the value is within its recorded range, targets the range minimum if zero doesn't fit. When the value is OUTSIDE its recorded range (a prior pass pushed it past the stale boundary), targets zero — the range is stale and the materializer will validate against the generator's fresh range.
    static func simplestTarget(for v: ChoiceSequenceValue.Value) -> ChoiceValue {
        let simplified = v.choice.semanticSimplest
        let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: v.validRange)
        if isWithinRecordedRange, simplified.fits(in: v.validRange) == false {
            guard let range = v.validRange else { return simplified }
            return ChoiceValue(v.choice.tag.makeConvertible(bitPattern64: range.lowerBound), tag: v.choice.tag)
        }
        return simplified
    }
}
