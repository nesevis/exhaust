//
//  GraphReplacementEncoder.swift
//  Exhaust
//

// MARK: - Graph Replacement Encoder

/// Applies a structural replacement to the base sequence.
///
/// Two operating modes:
///
/// - **Single-shot**: self-similar substitution and descendant promotion are atomic operations with one donor and one target. The encoder builds one candidate at ``start(scope:)`` and emits it from the next ``nextProbe(lastAccepted:)`` call.
///
/// - **Branch-pivot iterator**: a branch-pivot scope carries every non-selected alternative at a single pick site. The encoder caches the pick-site context at ``start(scope:)`` and walks ``BranchPivotScope/targetBranchIDs`` across probes. Each probe applies the leaf-count gate (skip when the candidate has more leaves than the current selection) and speculative one-shot leaf minimization (rewrite every `.choice` in the candidate subtree to its reduction target) before flattening. On any acceptance, the iterator stops because the cached tree no longer matches the live sequence — the next cycle's graph rebuild dispatches a fresh scope.
///
/// Bundling alternatives at the pick-site level instead of dispatching one scope per `(pick, alternative)` pair keeps the iteration inside one encoder lifetime, where the scheduler's priority queue cannot starve later candidates.
struct GraphReplacementEncoder: GraphEncoder {
    let name: EncoderName = .graphSubstitution

    private var mode: Mode = .idle

    private enum Mode {
        case idle
        case singleShot(probe: EncoderProbe?)
        case branchPivotIterator(BranchPivotIteratorState)
    }

    /// Cached state for the multi-probe branch-pivot iterator.
    ///
    /// Captures the pick-site context once at ``start(scope:)`` time so the encoder does not re-walk the tree on every probe. The iterator stays valid until the first acceptance; after that the cached `tree` and `elements` no longer match the live sequence and the iterator exits.
    private struct BranchPivotIteratorState {
        let pickNodeID: Int
        let tree: ChoiceTree
        let baseSequence: ChoiceSequence
        let fingerprint: Fingerprint
        let elements: [ChoiceTree]
        let isOpaque: Bool
        let selectedIndex: Int
        let currentLeafCount: Int
        /// Each entry pairs a `targetBranchIDs` index with the matching index in `elements`. Resolved once at start.
        let targets: [(elementIndex: Int, branchID: UInt64)]
        var nextTargetCursor: Int
    }

    mutating func start(scope: TransformationScope) {
        mode = .idle

        guard case let .replace(replacementScope) = scope.transformation.operation else {
            return
        }

        let sequence = scope.baseSequence
        let graph = scope.graph

        switch replacementScope {
        case let .selfSimilar(selfSimilarScope):
            let candidate = buildSelfSimilarCandidate(
                scope: selfSimilarScope,
                sequence: sequence,
                graph: graph
            )
            let probe = candidate.map {
                EncoderProbe(
                    candidate: $0,
                    mutation: .selfSimilarReplaced(
                        targetNodeID: selfSimilarScope.targetNodeID,
                        donorNodeID: selfSimilarScope.donorNodeID
                    )
                )
            }
            mode = .singleShot(probe: probe)

        case let .branchPivot(pivotScope):
            if let iteratorState = startBranchPivotIterator(
                scope: pivotScope,
                sequence: sequence,
                tree: scope.tree
            ) {
                mode = .branchPivotIterator(iteratorState)
            }

        case let .descendantPromotion(promotionScope):
            let candidate = buildDescendantPromotionCandidate(
                scope: promotionScope,
                sequence: sequence,
                graph: graph
            )
            let probe = candidate.map {
                EncoderProbe(
                    candidate: $0,
                    mutation: .descendantPromoted(
                        ancestorPickNodeID: promotionScope.ancestorPickNodeID,
                        descendantPickNodeID: promotionScope.descendantPickNodeID
                    )
                )
            }
            mode = .singleShot(probe: probe)
        }
    }

    mutating func nextProbe(lastAccepted: Bool) -> EncoderProbe? {
        switch mode {
        case .idle:
            return nil

        case let .singleShot(probe):
            mode = .idle
            return probe

        case var .branchPivotIterator(state):
            // Any acceptance invalidates the cached tree and elements; the
            // next cycle's graph rebuild will dispatch a fresh scope.
            if lastAccepted {
                mode = .idle
                return nil
            }
            let result = nextBranchPivotProbe(state: &state)
            mode = .branchPivotIterator(state)
            return result
        }
    }

    // MARK: - Candidate Construction

    /// Copies donor entries into the target's position range.
    private func buildSelfSimilarCandidate(
        scope: SelfSimilarReplacementScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let targetRange = graph.nodes[scope.targetNodeID].positionRange,
              let donorRange = graph.nodes[scope.donorNodeID].positionRange else {
            return nil
        }
        let donorEntries = Array(sequence[donorRange.lowerBound ... donorRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(targetRange.lowerBound ... targetRange.upperBound, with: donorEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    /// Resolves the pick-site context for a branch-pivot scope and returns an iterator state ready to walk the scope's `targetBranchIDs` across probes.
    ///
    /// Returns `nil` when the pick site cannot be located in the tree, when the located group has no `.selected` element, or when none of the scope's `targetBranchIDs` match an element in the group.
    private func startBranchPivotIterator(
        scope: BranchPivotScope,
        sequence: ChoiceSequence,
        tree: ChoiceTree
    ) -> BranchPivotIteratorState? {
        guard let fingerprint = findPickSiteFingerprint(
            in: tree,
            siteID: scope.siteID,
            selectedID: scope.selectedID
        ) else {
            return nil
        }

        guard case let .group(elements, isOpaque) = tree[fingerprint] else {
            return nil
        }
        guard let selectedIndex = elements.firstIndex(where: \.isSelected) else {
            return nil
        }

        // Resolve each branchID in the scope to its index in `elements`. Skip
        // branchIDs that no longer have a matching element (defensive — the
        // graph and tree should agree, but this keeps the iterator robust).
        var targets: [(elementIndex: Int, branchID: UInt64)] = []
        for branchID in scope.targetBranchIDs {
            guard let elementIndex = elements.firstIndex(where: { element in
                switch element {
                case let .branch(_, _, candidateID, _, _):
                    candidateID == branchID
                default:
                    false
                }
            }) else { continue }
            targets.append((elementIndex: elementIndex, branchID: branchID))
        }

        guard targets.isEmpty == false else { return nil }

        let currentLeafCount = Self.leafCount(in: elements[selectedIndex])

        return BranchPivotIteratorState(
            pickNodeID: scope.pickNodeID,
            tree: tree,
            baseSequence: sequence,
            fingerprint: fingerprint,
            elements: elements,
            isOpaque: isOpaque,
            selectedIndex: selectedIndex,
            currentLeafCount: currentLeafCount,
            targets: targets,
            nextTargetCursor: 0
        )
    }

    /// Walks the iterator state forward until it produces a candidate that passes every gate, or returns `nil` when the targets are exhausted.
    ///
    /// For each remaining target the helper applies the leaf-count gate (skip when the candidate has more leaves than the current selection), the speculative one-shot leaf minimization (rewrite every `.choice` in the candidate subtree to its reduction target), and a shortlex-equal-or-better check against the cached base sequence. Targets that fail any gate are skipped without leaving the call — gates are decided locally, not by the scheduler.
    private func nextBranchPivotProbe(
        state: inout BranchPivotIteratorState
    ) -> EncoderProbe? {
        while state.nextTargetCursor < state.targets.count {
            let target = state.targets[state.nextTargetCursor]
            state.nextTargetCursor += 1

            // Leaf-count gate. Count `.choice` leaves under the currently selected branch (N1) and under the candidate branch (N2). Only proceed when the candidate does not grow the sequence; candidates where N2 > N1 are almost always rejected by the decoder's shortlex check anyway, and dropping them here saves a probe.
            let candidateLeafCount = Self.leafCount(in: state.elements[target.elementIndex])
            guard candidateLeafCount <= state.currentLeafCount else { continue }

            // Speculative one-shot leaf minimization. Replace every `.choice` node in the candidate subtree with its reduction target before the swap. Without this, the candidate inherits whatever values the materializer produced for the non-selected branch in `.minimize` mode, which for recursive or bind-wrapped sub-generators is not always `value(0)`. Minimizing here ensures the shortlex comparison reflects only the structural difference between the current branch and the candidate, stripping out PRNG-like noise in the pre-materialized subtree.
            let minimizedTarget = Self.minimizingLeaves(in: state.elements[target.elementIndex])

            // Move .selected: unwrap from current, wrap the minimized target.
            var candidateElements = state.elements
            candidateElements[state.selectedIndex] = state.elements[state.selectedIndex].unwrapped
            candidateElements[target.elementIndex] = .selected(minimizedTarget)

            var candidateTree = state.tree
            candidateTree[state.fingerprint] = .group(candidateElements, isOpaque: state.isOpaque)
            let candidateSequence = ChoiceSequence(candidateTree)

            // Accept candidates that are shortlex-equal or better. With branch-transparent shortlex, pivoting between same-arity branches whose leaves are both at their reduction target may produce equal sequences — the property check determines whether the alternative is useful.
            guard state.baseSequence.shortLexPrecedes(candidateSequence) == false else {
                continue
            }
            return EncoderProbe(
                candidate: candidateSequence,
                mutation: .branchSelected(
                    pickNodeID: state.pickNodeID,
                    newSelectedID: target.branchID
                )
            )
        }
        return nil
    }

    /// Walks the tree depth-first to find the `.group(...)` whose selected branch matches the given siteID and selectedID.
    private func findPickSiteFingerprint(
        in tree: ChoiceTree,
        siteID: UInt64,
        selectedID: UInt64
    ) -> Fingerprint? {
        for element in tree.walk() {
            guard case let .group(array, _) = element.node else { continue }
            for child in array {
                if case let .selected(.branch(childSiteID, _, childID, _, _)) = child,
                   childSiteID == siteID,
                   childID == selectedID
                {
                    return element.fingerprint
                }
            }
        }
        return nil
    }

    /// Replaces the ancestor's range with the descendant's content.
    private func buildDescendantPromotionCandidate(
        scope: DescendantPromotionScope,
        sequence: ChoiceSequence,
        graph: ChoiceGraph
    ) -> ChoiceSequence? {
        guard let ancestorRange = graph.nodes[scope.ancestorPickNodeID].positionRange,
              let descendantRange = graph.nodes[scope.descendantPickNodeID].positionRange else {
            return nil
        }
        let descendantEntries = Array(sequence[descendantRange.lowerBound ... descendantRange.upperBound])
        var candidate = sequence
        candidate.replaceSubrange(ancestorRange.lowerBound ... ancestorRange.upperBound, with: descendantEntries)
        guard candidate.shortLexPrecedes(sequence) else { return nil }
        return candidate
    }

    // MARK: - Branch Pivot Helpers

    /// Counts leaf `.choice` nodes reachable from a ``ChoiceTree`` subtree.
    ///
    /// Recurses into every structural node without counting it, summing one for each `.choice` leaf encountered. The `.just` and `.getSize` cases contribute nothing. Used by ``nextBranchPivotProbe(state:)`` to compare the leaf counts of the currently selected branch and a candidate branch before deciding whether to emit the pivot candidate.
    private static func leafCount(in tree: ChoiceTree) -> Int {
        switch tree {
        case .choice:
            return 1
        case .just:
            return 0
        case .getSize:
            return 0
        case let .sequence(_, elements, _):
            var total = 0
            for element in elements {
                total += leafCount(in: element)
            }
            return total
        case let .branch(_, _, _, _, choice):
            return leafCount(in: choice)
        case let .group(children, _):
            var total = 0
            for child in children {
                total += leafCount(in: child)
            }
            return total
        case let .resize(_, choices):
            var total = 0
            for choice in choices {
                total += leafCount(in: choice)
            }
            return total
        case let .bind(inner, bound):
            return leafCount(in: inner) + leafCount(in: bound)
        case let .selected(inner):
            return leafCount(in: inner)
        }
    }

    /// Returns a copy of the subtree with every `.choice` node's value replaced by its ``ChoiceValue/reductionTarget(in:)``.
    ///
    /// Rewrites each `.choice` leaf to hold the bit pattern of its reduction target within the leaf's recorded valid range. Every structural node passes through unchanged, recursively rewriting its children. Used by ``nextBranchPivotProbe(state:)`` to strip PRNG-like noise from a candidate branch's pre-materialized subtree before flattening, so the subsequent shortlex comparison reflects only the structural difference between the current branch and the candidate.
    private static func minimizingLeaves(in tree: ChoiceTree) -> ChoiceTree {
        switch tree {
        case let .choice(value, metadata):
            let targetBP = value.reductionTarget(in: metadata.validRange)
            let targetValue = ChoiceValue(
                value.tag.makeConvertible(bitPattern64: targetBP),
                tag: value.tag
            )
            return .choice(targetValue, metadata)
        case .just:
            return tree
        case .getSize:
            return tree
        case let .sequence(length, elements, metadata):
            return .sequence(
                length: length,
                elements: elements.map { minimizingLeaves(in: $0) },
                metadata
            )
        case let .branch(siteID, weight, id, branchIDs, choice):
            return .branch(
                siteID: siteID,
                weight: weight,
                id: id,
                branchIDs: branchIDs,
                choice: minimizingLeaves(in: choice)
            )
        case let .group(children, isOpaque):
            return .group(
                children.map { minimizingLeaves(in: $0) },
                isOpaque: isOpaque
            )
        case let .resize(newSize, choices):
            return .resize(
                newSize: newSize,
                choices: choices.map { minimizingLeaves(in: $0) }
            )
        case let .bind(inner, bound):
            return .bind(
                inner: minimizingLeaves(in: inner),
                bound: minimizingLeaves(in: bound)
            )
        case let .selected(inner):
            return .selected(minimizingLeaves(in: inner))
        }
    }
}
