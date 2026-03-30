/// Speculative encoder that zeros one value by redistributing its magnitude to another.
///
/// For each pair of non-zero numeric values with matching tags, produces a single probe where the lhs is set to its reduction target (typically zero) and the rhs absorbs the full delta. The resulting sequence is likely shortlex-LARGER (the rhs moves away from zero), but the zeroed lhs enables deletion in a subsequent prune pass.
///
/// Conforms to ``AdaptiveEncoder`` rather than ``BatchEncoder`` because ``ReductionState/runRelaxRound(remaining:)`` drives it through a manual loop that needs per-probe decoder access. The `lastAccepted` feedback is ignored — each relaxation is independent, so acceptance of one pair does not inform which pair to try next.
///
/// Grade: `(.speculative, w)`. Requires pipeline acceptance — the caller must verify that the final state (after exploit passes) improves over the pre-relaxation checkpoint.
public struct RelaxRoundEncoder: ComposableEncoder {
    public init() {}

    public let name: EncoderName = .relaxRound
    public let phase = ReductionPhase.exploration

    // MARK: - Dual conformance disambiguation

    public var convergenceRecords: [Int: ConvergedOrigin] {
        [:]
    }

    // MARK: - ComposableEncoder

    public func estimatedCost(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange: ClosedRange<Int>,
        context: ReductionContext
    ) -> Int? {
        let valueCount = Self.extractFilteredSpans(from: sequence, in: positionRange, context: context).count
        guard valueCount >= 2 else { return nil }
        return valueCount * (valueCount - 1)
    }

    public mutating func start(
        sequence: ChoiceSequence,
        tree _: ChoiceTree,
        positionRange _: ClosedRange<Int>,
        context: ReductionContext
    ) {
        self.sequence = sequence
        probes = []
        probeIndex = 0

        let bindIndex = context.bindIndex

        // Sources: non-zero values that can be zeroed.
        // Sinks: all numeric values (including zeros) that can absorb magnitude.
        var sources: [(index: Int, value: ChoiceSequenceValue.Value, isBindInner: Bool)] = []
        var sinks: [(index: Int, value: ChoiceSequenceValue.Value, isBindInner: Bool)] = []
        var index = 0
        while index < sequence.count {
            if let value = sequence[index].value {
                switch value.choice {
                case .unsigned, .signed, .floating:
                    let isInner = bindIndex?.bindRegionForInnerIndex(index) != nil
                    sinks.append((index, value, isInner))
                    let target = value.choice.reductionTarget(
                        in: value.isRangeExplicit ? value.validRange : nil
                    )
                    if value.choice.bitPattern64 != target {
                        sources.append((index, value, isInner))
                    }
                }
            }
            index += 1
        }

        // Build pairs: lhs (source, to be zeroed) × rhs (sink, to absorb).
        // Never pair a bind-inner with a bound value — modifying the inner changes
        // the bound structure, making the bound modification meaningless.
        for source in sources {
            for sink in sinks where source.index != sink.index {
                guard source.value.choice.tag == sink.value.choice.tag else {
                    continue
                }
                guard source.isBindInner == sink.isBindInner else {
                    continue
                }
                probes.append((source.index, sink.index))
            }
        }

        // Sort order:
        // 1. Pairs where lhs is non-zero and rhs is at target (value relocation)
        //    come first, ordered by largest positional delta (rhs - lhs) descending.
        //    Moving a value rightward zeroes an earlier sequence position, which is
        //    the shortlex win.
        // 2. Remaining pairs (both non-zero) ordered by lhs distance descending —
        //    zero the largest values first.
        let seq = sequence
        probes.sort { lhs, rhs in
            let lhsIsRelocation = Self.distance(at: lhs.rhsIndex, in: seq) == 0
            let rhsIsRelocation = Self.distance(at: rhs.rhsIndex, in: seq) == 0
            if lhsIsRelocation != rhsIsRelocation {
                return lhsIsRelocation
            }
            if lhsIsRelocation {
                let lhsDelta = lhs.rhsIndex - lhs.lhsIndex
                let rhsDelta = rhs.rhsIndex - rhs.lhsIndex
                return lhsDelta > rhsDelta
            }
            return Self.distance(at: lhs.lhsIndex, in: seq) > Self.distance(at: rhs.lhsIndex, in: seq)
        }
    }

    // MARK: - State

    private var sequence = ChoiceSequence()
    private var probes: [(lhsIndex: Int, rhsIndex: Int)] = []
    private var probeIndex = 0

    public mutating func nextProbe(lastAccepted _: Bool) -> ChoiceSequence? {
        while probeIndex < probes.count {
            let pair = probes[probeIndex]
            probeIndex += 1

            guard let lhsValue = sequence[pair.lhsIndex].value,
                  let rhsValue = sequence[pair.rhsIndex].value,
                  lhsValue.choice.tag == rhsValue.choice.tag
            else { continue }

            let lhsBitPattern = lhsValue.choice.bitPattern64
            let target = lhsValue.choice.reductionTarget(
                in: lhsValue.isRangeExplicit ? lhsValue.validRange : nil
            )
            guard lhsBitPattern != target else { continue }

            // Full delta: zero the lhs completely.
            let delta: UInt64
            let lhsMovesUpward: Bool
            if target > lhsBitPattern {
                delta = target - lhsBitPattern
                lhsMovesUpward = true
            } else {
                delta = lhsBitPattern - target
                lhsMovesUpward = false
            }

            // Compute new rhs bit pattern.
            let rhsBitPattern = rhsValue.choice.bitPattern64
            let newRhsBitPattern: UInt64
            if lhsMovesUpward {
                // lhs increased toward target, rhs decreases by delta.
                guard rhsBitPattern >= delta else { continue }
                newRhsBitPattern = rhsBitPattern - delta
            } else {
                // lhs decreased toward target, rhs increases by delta.
                guard UInt64.max - delta >= rhsBitPattern else { continue }
                newRhsBitPattern = rhsBitPattern + delta
            }

            // Build probe entries.
            let newLhsChoice = ChoiceValue(
                lhsValue.choice.tag.makeConvertible(bitPattern64: target),
                tag: lhsValue.choice.tag
            )
            let newRhsChoice = ChoiceValue(
                rhsValue.choice.tag.makeConvertible(bitPattern64: newRhsBitPattern),
                tag: rhsValue.choice.tag
            )

            // Validate rhs stays in range if range-explicit.
            if rhsValue.isRangeExplicit, newRhsChoice.fits(in: rhsValue.validRange) == false {
                continue
            }

            let lhsEntry = ChoiceSequenceValue.reduced(.init(
                choice: newLhsChoice,
                validRange: lhsValue.validRange,
                isRangeExplicit: lhsValue.isRangeExplicit
            ))
            let rhsEntry = ChoiceSequenceValue.value(.init(
                choice: newRhsChoice,
                validRange: rhsValue.validRange,
                isRangeExplicit: rhsValue.isRangeExplicit
            ))

            var probe = sequence
            probe[pair.lhsIndex] = lhsEntry
            probe[pair.rhsIndex] = rhsEntry
            return probe
        }
        return nil
    }

    // MARK: - Helpers

    private static func distance(at index: Int, in sequence: ChoiceSequence) -> UInt64 {
        guard let value = sequence[index].value else { return 0 }
        let bitPattern = value.choice.bitPattern64
        let target = value.choice.reductionTarget(
            in: value.isRangeExplicit ? value.validRange : nil
        )
        return bitPattern > target ? bitPattern - target : target - bitPattern
    }
}
