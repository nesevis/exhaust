/// Sets each target value to its semantic simplest form (zero for numerics), or to the
/// range's lower bound when zero falls outside an explicit valid range.
///
/// Produces one candidate per target span. The scheduler evaluates in order, stopping at the first success. The 2-cell chain ZeroValue => BinarySearchToZero means that targets where ZeroValue succeeds can skip binary search entirely.
public struct ZeroValueEncoder: BatchEncoder {
    public let name = "zeroValue"
    public let phase = ReductionPhase.valueMinimization

    public var grade: ReductionGrade {
        ReductionGrade(approximation: .exact, maxMaterializations: 0)
    }

    public func encode(
        sequence: ChoiceSequence,
        targets: TargetSet
    ) -> any Sequence<ChoiceSequence> {
        guard case let .spans(spans) = targets else { return [] as [ChoiceSequence] }

        // First: try setting ALL values to their simplest simultaneously.
        // This handles filter-coupled generators where individual changes break
        // coupling constraints but the all-simplest candidate preserves them.
        // Matches the legacy reducer's naiveSimplifyValuesToSemanticSimplest pass.
        var allSimplest = sequence
        var anyChanged = false
        for span in spans {
            let seqIdx = span.range.lowerBound
            guard let v = sequence[seqIdx].value else { continue }
            let target = Self.simplestTarget(for: v)
            guard target != v.choice else { continue }
            allSimplest[seqIdx] = .value(.init(
                choice: target,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit
            ))
            anyChanged = true
        }
        let allSimplestPrefix: [ChoiceSequence] = anyChanged ? [allSimplest] : []

        // Then: try each value individually.
        let individual = spans.lazy.compactMap { span -> ChoiceSequence? in
            let seqIdx = span.range.lowerBound
            guard let v = sequence[seqIdx].value else { return nil }
            let target = Self.simplestTarget(for: v)
            guard target != v.choice else { return nil }
            var candidate = sequence
            candidate[seqIdx] = .value(.init(
                choice: target,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit
            ))
            return candidate
        }

        return allSimplestPrefix + Array(individual)
    }

    /// Returns the simplest valid target for a value.
    ///
    /// Stale-range escape hatch (matches legacy reduceIntegralValues): when the
    /// value is within its recorded range, targets the range minimum if zero doesn't
    /// fit. When the value is OUTSIDE its recorded range (a prior pass pushed it past
    /// the stale boundary), targets zero — the range is stale and the materializer
    /// will validate against the generator's fresh range.
    private static func simplestTarget(for v: ChoiceSequenceValue.Value) -> ChoiceValue {
        let simplified = v.choice.semanticSimplest
        let isWithinRecordedRange = v.isRangeExplicit && v.choice.fits(in: v.validRange)
        if isWithinRecordedRange, simplified.fits(in: v.validRange) == false {
            guard let range = v.validRange else { return simplified }
            return ChoiceValue(v.choice.tag.makeConvertible(bitPattern64: range.lowerBound), tag: v.choice.tag)
        }
        return simplified
    }
}
