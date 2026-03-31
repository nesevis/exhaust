// MARK: - Mutation Pool

//
// Pairs of non-overlapping structural deletions that the sequential adaptive loop cannot discover.
// The pushout law (fibration composition): two deletion span sets whose ranges are disjoint compose
// by union, and `removeSubranges(RangeSet)` is the canonical pushout of the two reduced structures.

/// A candidate entry in the mutation pool, representing a single or composed structural deletion.
struct MutationPoolEntry {
    /// All spans covered by this candidate.
    let spans: [ChoiceSpan]
    /// The mutated sequence that deletes all spans at once.
    let candidate: ChoiceSequence
    /// Sum of span range lengths; used as a shortlex rank estimate (larger = more deleted = tried first).
    let deletedLength: Int
}

/// Composes non-overlapping structural deletions for Phase 1b fallback.
///
/// The sequential adaptive loop in Phase 1b finds the largest batch of same-depth, same-category spans that is individually accepted. Two non-overlapping batches that are each rejected individually may be jointly accepted (property still fails when both are deleted). `MutationPool` collects individual deletion candidates and composes disjoint pairs, ranked by total deleted length.
///
/// - SeeAlso: ``ReductionState/runStructuralDeletion(budget:dependencyGraph:)``
enum MutationPool {
    static let individualLimit = 20
    static let pairLimit = 190 // C(20, 2)

    /// Collects individual deletion candidates from the span cache for all scope × slot combinations.
    ///
    /// Mirrors the scope/slot iteration structure of `runStructuralDeletion`. For each (scope, slot) pair with non-empty targets, builds a candidate that deletes all those spans simultaneously. Returns the top-`individualLimit` entries by `deletedLength`, descending.
    static func collect(
        sequence: ChoiceSequence,
        spanCache: inout SpanCache,
        scopes: [DeletionScope],
        slots: [ReductionScheduler.DeletionEncoderSlot],
        bindIndex: BindSpanIndex?
    ) -> [MutationPoolEntry] {
        var entries = [MutationPoolEntry]()

        for scope in scopes {
            for slot in slots {
                let spans: [ChoiceSpan] = if let positionRange = scope.positionRange {
                    spanCache.deletionTargets(
                        category: slot.spanCategory,
                        inRange: positionRange,
                        from: sequence
                    )
                } else {
                    spanCache.deletionTargets(
                        category: slot.spanCategory,
                        depth: scope.depth,
                        from: sequence,
                        bindIndex: bindIndex
                    )
                }
                guard spans.isEmpty == false else { continue }

                var rangeSet = RangeSet<Int>()
                var deletedLength = 0
                for span in spans {
                    rangeSet.insert(contentsOf: span.range.asRange)
                    deletedLength += span.range.count
                }
                var candidate = sequence
                candidate.removeSubranges(rangeSet)
                guard candidate.shortLexPrecedes(sequence) else { continue }

                entries.append(MutationPoolEntry(
                    spans: spans,
                    candidate: candidate,
                    deletedLength: deletedLength
                ))
            }
        }

        entries.sort { $0.deletedLength > $1.deletedLength }
        if entries.count > individualLimit {
            entries = Array(entries.prefix(individualLimit))
        }
        return entries
    }

    /// Composes non-overlapping pairs from individual pool entries into joint deletion candidates.
    ///
    /// For each pair (a, b) where all spans are disjoint, unions both `RangeSet`s and applies `removeSubranges` once. Pairs where any span of `a` overlaps any span of `b` are skipped — the ancestor already appears as an individual entry. Returns up to `pairLimit` valid compositions, in discovery order.
    static func composePairs(
        from entries: [MutationPoolEntry],
        sequence: ChoiceSequence
    ) -> [MutationPoolEntry] {
        var pairs = [MutationPoolEntry]()

        var outerIdx = 0
        while outerIdx < entries.count {
            var innerIdx = outerIdx + 1
            while innerIdx < entries.count {
                let a = entries[outerIdx]
                let b = entries[innerIdx]

                if areDisjoint(a.spans, b.spans) {
                    var rangeSet = RangeSet<Int>()
                    for span in a.spans {
                        rangeSet.insert(contentsOf: span.range.asRange)
                    }
                    for span in b.spans {
                        rangeSet.insert(contentsOf: span.range.asRange)
                    }
                    var candidate = sequence
                    candidate.removeSubranges(rangeSet)
                    guard candidate.shortLexPrecedes(sequence) else {
                        innerIdx += 1
                        continue
                    }
                    pairs.append(MutationPoolEntry(
                        spans: a.spans + b.spans,
                        candidate: candidate,
                        deletedLength: a.deletedLength + b.deletedLength
                    ))
                    if pairs.count >= pairLimit {
                        return pairs
                    }
                }
                innerIdx += 1
            }
            outerIdx += 1
        }
        return pairs
    }

    /// Returns true if no span in `a` overlaps any span in `b`.
    private static func areDisjoint(_ a: [ChoiceSpan], _ b: [ChoiceSpan]) -> Bool {
        for spanA in a {
            for spanB in b {
                if spanA.range.asRange.overlaps(spanB.range.asRange) {
                    return false
                }
            }
        }
        return true
    }
}
