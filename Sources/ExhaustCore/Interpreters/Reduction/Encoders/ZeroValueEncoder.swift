/// Sets each target value to its semantic simplest form (zero for numerics).
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

        // First: try setting ALL values to zero simultaneously.
        // This handles filter-coupled generators where individual changes break
        // coupling constraints but the all-zero candidate preserves them.
        // Matches the legacy reducer's naiveSimplifyValuesToSemanticSimplest pass.
        var allZero = sequence
        var anyChanged = false
        for span in spans {
            let seqIdx = span.range.lowerBound
            guard let v = sequence[seqIdx].value else { continue }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice else { continue }
            guard v.isRangeExplicit == false || simplified.fits(in: v.validRange) else { continue }
            allZero[seqIdx] = .value(.init(
                choice: simplified,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit
            ))
            anyChanged = true
        }
        let allZeroPrefix: [ChoiceSequence] = anyChanged ? [allZero] : []

        // Then: try each value individually.
        let individual = spans.lazy.compactMap { span -> ChoiceSequence? in
            let seqIdx = span.range.lowerBound
            guard let v = sequence[seqIdx].value else { return nil }
            let simplified = v.choice.semanticSimplest
            guard simplified != v.choice else { return nil }
            guard v.isRangeExplicit == false || simplified.fits(in: v.validRange) else { return nil }
            var candidate = sequence
            candidate[seqIdx] = .value(.init(
                choice: simplified,
                validRange: v.validRange,
                isRangeExplicit: v.isRangeExplicit
            ))
            return candidate
        }

        return allZeroPrefix + Array(individual)
    }
}
