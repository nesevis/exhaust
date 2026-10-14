//
//  ScopedRemovalEncoder.swift
//  Exhaust
//

// MARK: - Removal Encoder

/// Deletes elements, aligned elements across sibling sequences, or a growing window of elements.
///
/// Element scopes fully determine their probe. Aligned scopes emit one probe per covering array row. Every accepted removal requires a rebuild, which ends the pass, except for windows: each window probe removes a nested set from the dispatch-time base, so window search keeps going after an acceptance.
struct ScopedRemovalEncoder: ScopedEncoder {
    /// A removal the families can build.
    enum Scope {
        /// Elements of one or more sequences, removed together in one probe.
        case elements(ElementRemovalScope)
        /// One element from each of two or more sibling sequences per probe, chosen by a covering array.
        case coveringAligned(CoveringAlignedRemovalScope)
        /// A window grown from an interior anchor, the center, or both edges.
        case window(WindowRemovalScope)
    }

    static let name: EncoderName = .deletion
    static let isValueDependent = false
    static let requiresGenerator = false
    static let isPathChanging = false
    let tuning: ScopedReductionTuning

    func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer {
        let sequence = input.baseSequence
        let graph = input.graph
        switch scope {
            case let .elements(elementScope):
                guard let candidate = ScopedStructuralCandidates.elementRemoval(elementScope, sequence: sequence, graph: graph) else {
                    return Self.search(.singleCandidate(ScopedSingleCandidateSearch()))
                }
                let mutation = EncoderProbe.sequenceElementsRemoved(
                    elementScope.targets.map { target in
                        (seqNodeID: target.sequenceNodeID, removedNodeIDs: target.elementNodeIDs)
                    }
                )
                return Self.search(.singleCandidate(ScopedSingleCandidateSearch(candidate: candidate, mutation: mutation)))
            case let .coveringAligned(alignedScope):
                return Self.search(.coveringAlignedRemoval(ScopedCoveringAlignedRemovalSearch(
                    scope: alignedScope,
                    baseSequence: sequence,
                    graph: graph
                )))
            case let .window(windowScope):
                return Self.search(
                    .windowRemoval(ScopedWindowRemovalSearch(scope: windowScope, baseSequence: sequence, graph: graph)),
                    acceptance: .rebuildAndContinue
                )
        }
    }

    // MARK: - Helpers

    private static func search(_ search: ScopedSearchKind, acceptance: ScopedAcceptance = .continue) -> ScopedReducer {
        .search(
            search,
            configuration: ScopedSearchConfiguration(
                acceptance: acceptance,
                requiresExactDecoder: false,
                reportedMutation: nil
            )
        )
    }
}
