//
//  CoveringAlignedRemovalSearch.swift
//  Exhaust
//

// MARK: - Covering Aligned Removal Search

/// Deletes one element from each of two or more sibling sequences per probe, choosing the combinations from a strength-2 covering array.
///
/// Each row is an array of `UInt64` values, one per sibling parameter. A value equal to the sibling's skip value (its element count) means "do not delete from this sibling." Any other value is an element index within that sibling's `elementNodeIDs`. Rows where fewer than two siblings participate are skipped, because deletion within one sequence belongs to batch removal.
///
/// The covering array generator is a reference shared with the scope, so a later search over the same scope resumes where this one stopped. Every accepted deletion requires a rebuild, which ends the pass, so the search never sees an acceptance.
///
/// One search pulls at most ``CoveringAlignedRemovalScope/rowBudget`` rows, counting rows skipped without a candidate, since they cost no trial and so never reach the deadline check. Without the budget, a sibling pair too large for the generator to track yields rows forever.
struct CoveringAlignedRemovalSearch: ReductionSearch {
    private let scope: CoveringAlignedRemovalScope
    private let baseSequence: ChoiceSequence
    private let graph: ChoiceGraph
    private var isExhausted = false
    private var rowsPulled = 0

    init(scope: CoveringAlignedRemovalScope, baseSequence: ChoiceSequence, graph: ChoiceGraph) {
        self.scope = scope
        self.baseSequence = baseSequence
        self.graph = graph
    }

    mutating func next(_: SearchFeedback, into buffer: inout ChoiceSequence) -> ReductionCandidate? {
        guard isExhausted == false else {
            return nil
        }

        while rowsPulled < CoveringAlignedRemovalScope.rowBudget, let row = scope.generator.next() {
            rowsPulled += 1
            // Decode the row into deletion targets.
            var targets: [SequenceRemovalTarget] = []
            var removedPairs: [(seqNodeID: Int, removedNodeIDs: [Int])] = []

            for (siblingIndex, value) in row.values.enumerated() {
                guard siblingIndex < scope.siblings.count else {
                    continue
                }
                if value == scope.skipValues[siblingIndex] {
                    continue
                }
                let elementIndex = Int(value)
                let sibling = scope.siblings[siblingIndex]
                guard elementIndex < sibling.elementNodeIDs.count else {
                    continue
                }
                let nodeID = sibling.elementNodeIDs[elementIndex]
                targets.append(SequenceRemovalTarget(
                    sequenceNodeID: sibling.sequenceNodeID,
                    elementNodeIDs: [nodeID]
                ))
                removedPairs.append((
                    seqNodeID: sibling.sequenceNodeID,
                    removedNodeIDs: [nodeID]
                ))
            }

            guard targets.count >= 2 else {
                continue
            }

            let elementScope = ElementRemovalScope(
                targets: targets,
                maxBatch: 1,
                maxElementYield: scope.maxElementYield
            )

            guard let built = StructuralCandidates.elementRemoval(
                elementScope,
                sequence: baseSequence,
                graph: graph
            ) else {
                continue
            }

            buffer = built
            return .written(mutation: .sequenceElementsRemoved(removedPairs), admission: .standard)
        }

        isExhausted = true
        return nil
    }
}
