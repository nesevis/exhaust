// Multi-probe mutation campaigns: coordinated probe sessions replacing one parent visit's child batch.
//
// A campaign spends the parent's child budget on a sequence of related candidates instead of independent draws: the value walk steers each probe by the previous probe's outcome, the region sweep enumerates covering rows over one bind region. Both run only when the parent's stall gate is open — the cheap arms have gone ``FuzzTunables/campaignStallThreshold`` children without an admission — so the multi-probe spend lands where independent draws have stopped paying.

extension FuzzRunner {
    /// Runs one campaign against the parent, consuming up to `budget` evaluations. Returns false without consuming budget when neither campaign can target this parent.
    ///
    /// The campaign kind is a fair draw; a kind that cannot target the parent (no eligible leaf, no bind region) falls through to the other.
    func runCampaign(parent: CorpusEntry, parentIndex: Int, budget: Int) -> Bool {
        guard let graph = corpus.mutationTargets(forParentAt: parentIndex)?.graph else {
            return false
        }
        switch FuzzTunables.campaignKindOverride {
            case "sweep":
                return runRegionSweep(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
            case "walk":
                return runValueWalk(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
            default:
                break
        }
        if prng.next(upperBound: 2) == 0 {
            return runValueWalk(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
                || runRegionSweep(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
        }
        return runRegionSweep(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
            || runValueWalk(parent: parent, parentIndex: parentIndex, graph: graph, budget: budget)
    }

    // MARK: - Value Walk

    /// An adaptive walk on one leaf: each accepted probe doubles the step and walks on from the accepted value, each rejected probe flips direction and resets the step.
    ///
    /// A probe is accepted when its evaluation was valid (materialized and not discarded) or admitted — the walk climbs toward precondition-satisfying regions on sparse workloads and drifts directionally on dense ones. A step that would leave the leaf's domain clamps to the boundary; at the boundary the walk flips instead of re-probing the same value.
    private func runValueWalk(
        parent: CorpusEntry,
        parentIndex: Int,
        graph: ChoiceGraph,
        budget: Int
    ) -> Bool {
        var positions: [Int] = []
        for nodeID in graph.leafNodes {
            let node = graph.nodes[nodeID]
            if node.scopeAnnotation.isDepthControl || node.scopeAnnotation.isLaneControl {
                continue
            }
            guard let range = node.positionRange, range.lowerBound < parent.sequence.count else {
                continue
            }
            positions.append(range.lowerBound)
        }
        guard positions.isEmpty == false else {
            return false
        }
        let position = positions[Int(prng.next(upperBound: UInt64(positions.count)))]
        guard case let .value(entry) = parent.sequence[position] else {
            return false
        }
        let tag = entry.choice.tag
        let domain = entry.validRange ?? tag.bitPatternRange

        var shiftUpward = prng.next(upperBound: 2) == 0
        var step: UInt64 = 1
        var basePattern = entry.choice.bitPattern64
        var produced = false
        for _ in 0 ..< budget {
            if terminationDue() != nil {
                break
            }
            let headroom = shiftUpward
                ? domain.upperBound - basePattern
                : basePattern - domain.lowerBound
            guard headroom > 0 else {
                shiftUpward = shiftUpward == false
                step = 1
                continue
            }
            let delta = min(step, headroom)
            let candidatePattern = shiftUpward ? basePattern + delta : basePattern - delta

            var candidate = parent.sequence
            candidate[position] = .value(.init(
                choice: ChoiceValue(candidatePattern, tag: tag),
                validRange: entry.validRange,
                isRangeExplicit: entry.isRangeExplicit
            ))
            openMutationAttempt()
            counts.campaignAttempts += 1
            let feedback = evaluateFuzzCandidate(
                candidate,
                parent: parent,
                parentIndex: parentIndex,
                armsMask: 1 << UInt32(MutationArm.valueWalk.rawValue)
            )
            produced = true
            let accepted = feedback.admitted
                || (feedback.materialized && feedback.discarded == false)
            if accepted {
                basePattern = candidatePattern
                step = step > UInt64.max / 2 ? UInt64.max : step * 2
            } else {
                shiftUpward = shiftUpward == false
                step = 1
            }
        }
        return produced
    }

    // MARK: - Region Sweep

    /// A covering sweep over one bind region's leaves inside an otherwise-fixed parent, via ``BoundValueCoveringEncoder``: exhaustive for small joint domains, pairwise-covering rows otherwise.
    private func runRegionSweep(
        parent: CorpusEntry,
        parentIndex: Int,
        graph: ChoiceGraph,
        budget: Int
    ) -> Bool {
        var regions: [ClosedRange<Int>] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .bind(metadata) = node.kind,
                  metadata.boundChildIndex < node.children.count,
                  let range = graph.nodes[node.children[metadata.boundChildIndex]].positionRange,
                  range.upperBound < parent.sequence.count
            else {
                continue
            }
            regions.append(range)
        }
        guard regions.isEmpty == false else {
            return false
        }
        let region = regions[Int(prng.next(upperBound: UInt64(regions.count)))]

        var encoder = BoundValueCoveringEncoder()
        encoder.start(sequence: parent.sequence, tree: parent.tree, positionRange: region)
        var produced = false
        for _ in 0 ..< budget {
            if terminationDue() != nil {
                break
            }
            guard let candidate = encoder.nextProbe(lastAccepted: false) else {
                break
            }
            openMutationAttempt()
            counts.campaignAttempts += 1
            evaluateFuzzCandidate(
                candidate,
                parent: parent,
                parentIndex: parentIndex,
                armsMask: 1 << UInt32(MutationArm.regionSweep.rawValue)
            )
            produced = true
        }
        return produced
    }
}
