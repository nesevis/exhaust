/// Caches span extractions to avoid redundant O(n) walks of the choice sequence.
///
/// Span extraction functions (`extractAllValueSpans`, `extractSiblingGroups`, etc.)
/// are called multiple times per leg with identical inputs. The cache lazily stores
/// each extraction's result and is invalidated when the sequence structure changes
/// (via `accept(structureChanged: true)`) or at leg boundaries.
struct SpanCache {
    private var cachedAllValueSpans: [ChoiceSpan]?
    private var cachedSiblingGroups: [SiblingGroup]?
    private var cachedContainerSpans: [ChoiceSpan]?
    private var cachedSequenceElementSpans: [ChoiceSpan]?
    private var cachedSequenceBoundarySpans: [ChoiceSpan]?
    private var cachedFreeStandingValueSpans: [ChoiceSpan]?

    mutating func invalidate() {
        cachedAllValueSpans = nil
        cachedSiblingGroups = nil
        cachedContainerSpans = nil
        cachedSequenceElementSpans = nil
        cachedSequenceBoundarySpans = nil
        cachedFreeStandingValueSpans = nil
    }

    // MARK: - Raw cached extractions

    private mutating func allValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = cachedAllValueSpans { return cached }
        let result = ChoiceSequence.extractAllValueSpans(from: sequence)
        cachedAllValueSpans = result
        return result
    }

    private mutating func allSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
        if let cached = cachedSiblingGroups { return cached }
        let result = ChoiceSequence.extractSiblingGroups(from: sequence)
        cachedSiblingGroups = result
        return result
    }

    private mutating func allContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = cachedContainerSpans { return cached }
        let result = ChoiceSequence.extractContainerSpans(from: sequence)
        cachedContainerSpans = result
        return result
    }

    private mutating func allSequenceElementSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = cachedSequenceElementSpans { return cached }
        let result = ChoiceSequence.extractSequenceElementSpans(from: sequence)
        cachedSequenceElementSpans = result
        return result
    }

    private mutating func allSequenceBoundarySpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = cachedSequenceBoundarySpans { return cached }
        let result = ChoiceSequence.extractSequenceBoundarySpans(from: sequence)
        cachedSequenceBoundarySpans = result
        return result
    }

    private mutating func allFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = cachedFreeStandingValueSpans { return cached }
        let result = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
        cachedFreeStandingValueSpans = result
        return result
    }

    // MARK: - Depth-filtered accessors

    mutating func valueSpans(
        at depth: Int, from sequence: ChoiceSequence, bindIndex: BindSpanIndex?
    ) -> [ChoiceSpan] {
        let all = allValueSpans(from: sequence)
        if let bi = bindIndex {
            return all.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
        }
        return all
    }

    mutating func siblingGroups(
        at depth: Int, from sequence: ChoiceSequence, bindIndex: BindSpanIndex?
    ) -> [SiblingGroup] {
        let all = allSiblingGroups(from: sequence)
        if let bi = bindIndex {
            return all.filter { bi.bindDepth(at: $0.ranges[0].lowerBound) == depth }
        }
        return all
    }

    mutating func floatSpans(
        at depth: Int, from sequence: ChoiceSequence, bindIndex: BindSpanIndex?
    ) -> [ChoiceSpan] {
        valueSpans(at: depth, from: sequence, bindIndex: bindIndex).filter { span in
            guard let v = sequence[span.range.lowerBound].value else { return false }
            return v.choice.tag == .double || v.choice.tag == .float
        }
    }

    mutating func deletionTargets(
        category: DeletionSpanCategory, depth: Int,
        from sequence: ChoiceSequence, bindIndex: BindSpanIndex?
    ) -> [ChoiceSpan] {
        let spans = rawDeletionSpans(category: category, from: sequence)
        if let bi = bindIndex {
            return spans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
        }
        return spans
    }

    /// Returns deletion targets whose start position falls within the given range.
    ///
    /// Used by DAG-driven structural deletion to scope targets to a specific node's position range.
    mutating func deletionTargets(
        category: DeletionSpanCategory,
        inRange positionRange: ClosedRange<Int>,
        from sequence: ChoiceSequence
    ) -> [ChoiceSpan] {
        let spans = rawDeletionSpans(category: category, from: sequence)
        return spans.filter { positionRange.contains($0.range.lowerBound) }
    }

    /// Extracts raw (unfiltered) spans for a deletion category.
    private mutating func rawDeletionSpans(
        category: DeletionSpanCategory,
        from sequence: ChoiceSequence
    ) -> [ChoiceSpan] {
        switch category {
        case .containerSpans:
            allContainerSpans(from: sequence)
        case .sequenceElements:
            allSequenceElementSpans(from: sequence)
        case .sequenceBoundaries:
            allSequenceBoundarySpans(from: sequence)
        case .freeStandingValues:
            allFreeStandingValueSpans(from: sequence)
        case .siblingGroups, .mixed:
            allContainerSpans(from: sequence)
        }
    }
}
