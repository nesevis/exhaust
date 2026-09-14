// Graph-targeted mutation operators over the admission-time scope caches.
//
// Each operator resolves its positions through the parent's stored ChoiceGraph and edits the candidate with the shared sequence writers. Positions are admission-time facts about the parent, so a candidate that has already drifted structurally under a stacked mutation may be mis-targeted; every range is therefore bounds-checked against the candidate, an out-of-range operator is a cheap miss, and guided materialization absorbs any structural error a blind application introduces.

// MARK: - Mutation Targets

/// The graph and scope caches one corpus entry's graph-targeted operators resolve their positions through.
///
/// Built once at admission and read-only for the entry's lifetime: entries never change in place, so the graph is never rebuilt and never has `apply` called on it. The scopes are cached rather than rebuilt per mutation because each query walks the whole graph. Only mutable-tier entries become mutation parents, so only they pay for these — a discovery-tier entry carries no targets at all.
package struct MutationTargets: Sendable {
    /// Resolves the scopes' node IDs to position ranges without a tree walk.
    package let graph: ChoiceGraph

    /// Same-tag leaf groups from ``ExchangeQuery``. Nil when the graph has no group of two or more leaves.
    let tandem: TandemScope?

    /// Same-shaped zip sibling groups from ``PermutationQuery``.
    let permutationScopes: [PermutationScope]

    /// Position ranges of twin spans under a common zip, grouped by twin key: siblings the generator drew from the same site, in position order within each group.
    let twinSpanGroups: [[ClosedRange<Int>]]

    /// The graph's self-similarity fingerprints in ascending order, so typed crossover's per-draw walk is a fixed order without sorting dictionary keys on every call.
    let sortedFingerprints: [UInt64]

    /// Sequence nodes with two or more elements, eligible for element deletion. Each entry is the node ID of a sequence whose elements can be individually removed.
    let deletableSequenceNodeIDs: [Int]

    /// Sequence nodes with one or more elements, eligible for element duplication.
    let duplicableSequenceNodeIDs: [Int]

    /// One site a value reseed may draw fresh: an independent chooseBits leaf or pick node, with its span and the sites that contain it.
    struct ReseedSite {
        let nodeID: Int
        let range: ClosedRange<Int>
        /// Indices into ``MutationTargets/reseedSites`` of the sites whose spans contain this one, so an antichain draw can reject a nested pair without walking the graph.
        let containingSiteIndices: [Int]
    }

    /// Every site a value reseed may target, ascending by position. Leaves and picks under a bind's inner subtree are excluded: a fresh value there regenerates the bound region, which is the cascade the reseed exists to avoid.
    let reseedSites: [ReseedSite]

    /// Indices into ``reseedSites`` of the sites no other site contains, which is what "reseed all" draws: the maximal antichain, covering every reseedable span once.
    let maximalReseedSiteIndices: [Int]

    /// The arms whose first guard this entry's own tables satisfy: the sibling-span operators, the lockstep delta, and the twin splice.
    ///
    /// Answered once at construction because the tables never change and each query walks every scope. Read per draw when the eligibility gate is on, so a scan there would be paid on every candidate. `typedCrossover` is not included: its donor half is a corpus fact, see ``hasCrossoverDonor(corpus:)``.
    package private(set) var structuralArms: MutationArmSet

    /// Whether any swappable sibling group has at least `minimumSize` members, which is the first guard of every sibling-span operator.
    ///
    /// The second guard, that the group's cached position ranges still fit the candidate, is a staleness check rather than an applicability one and cannot be answered from the parent alone.
    package func hasSwappableGroup(minimumSize: Int) -> Bool {
        for scope in permutationScopes {
            for group in scope.swappableGroups where group.count >= minimumSize {
                return true
            }
        }
        return false
    }

    /// Whether a tandem group has the two leaves the lockstep delta needs. A scope whose groups are all singletons passes the scope check and fails at the draw.
    package var hasTandemGroup: Bool {
        guard let tandem else {
            return false
        }
        return tandem.groups.contains { $0.leaves.count >= 2 }
    }

    /// Whether a twin group has the two spans the twin splice copies between.
    package var hasTwinGroup: Bool {
        twinSpanGroups.contains { $0.count >= 2 }
    }

    /// Whether any fingerprint has both a recipient in this parent and a donor span from a different entry in the corpus.
    ///
    /// The only precondition here that depends on the corpus rather than the parent, so it cannot be cached at admission: a fingerprint gains donors as other entries are admitted. Excludes the parent's own spans because ``FuzzMutator/typedCrossover(_:parentHash:targets:corpus:prng:)`` rejects self-donation.
    package func hasCrossoverDonor(corpus: FuzzCorpus, parentIndex: Int) -> Bool {
        for fingerprint in sortedFingerprints {
            guard let recipients = graph.selfSimilarityGroups[fingerprint],
                  recipients.isEmpty == false,
                  let donors = corpus.donorSpansByFingerprint[fingerprint],
                  donors.contains(where: { $0.entryIndex != parentIndex })
            else {
                continue
            }
            return true
        }
        return false
    }

    /// Builds the targeting tables for one entry's tree.
    ///
    /// Relation scopes are convergence-gated and always empty on a fresh graph, so they are not cached. Construction consumes no PRNG draws, so seeded replay streams are unchanged.
    init(tree: ChoiceTree) {
        let graph = ChoiceGraphBuilder.build(from: tree)
        var tandem: TandemScope?
        for exchangeScope in ExchangeQuery.build(graph: graph) {
            if case let .tandem(scope) = exchangeScope {
                tandem = scope
            }
        }
        self.graph = graph
        self.tandem = tandem
        permutationScopes = PermutationQuery.build(graph: graph)
        twinSpanGroups = FuzzMutator.twinSpanGroups(graph: graph)
        sortedFingerprints = graph.selfSimilarityGroups.keys.sorted()

        let removalScopes = RemovalQuery.elementRemovalScopes(graph: graph)
        deletableSequenceNodeIDs = removalScopes.compactMap { $0.targets.first?.sequenceNodeID }

        var duplicable: [Int] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case let .sequence(metadata) = node.kind else { continue }
            let upper = metadata.lengthConstraint?.upperBound ?? UInt64.max
            if metadata.elementCount >= 1, UInt64(metadata.elementCount + 1) <= upper {
                duplicable.append(nodeID)
            }
        }
        duplicableSequenceNodeIDs = duplicable

        var siteNodeIDs: [Int] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard node.positionRange != nil, node.scopeAnnotation.isBindInner == false else { continue }
            switch node.kind {
                case .chooseBits:
                    guard node.scopeAnnotation.isDepthControl == false, node.scopeAnnotation.isLaneControl == false else { continue }
                case .pick:
                    break
                default:
                    continue
            }
            siteNodeIDs.append(nodeID)
        }
        siteNodeIDs.sort { graph.nodes[$0].positionRange!.lowerBound < graph.nodes[$1].positionRange!.lowerBound }
        var siteIndexByNodeID: [Int: Int] = [:]
        for (index, nodeID) in siteNodeIDs.enumerated() {
            siteIndexByNodeID[nodeID] = index
        }
        var sites: [ReseedSite] = []
        sites.reserveCapacity(siteNodeIDs.count)
        var maximal: [Int] = []
        for (index, nodeID) in siteNodeIDs.enumerated() {
            var containing: [Int] = []
            var ancestor = graph.nodes[nodeID].parent
            while let current = ancestor {
                if let siteIndex = siteIndexByNodeID[current] {
                    containing.append(siteIndex)
                }
                ancestor = graph.nodes[current].parent
            }
            sites.append(ReseedSite(nodeID: nodeID, range: graph.nodes[nodeID].positionRange!, containingSiteIndices: containing))
            if containing.isEmpty {
                maximal.append(index)
            }
        }
        reseedSites = sites
        maximalReseedSiteIndices = maximal

        structuralArms = .none
        var structural = MutationArmSet.none
        if hasSwappableGroup(minimumSize: 2) {
            structural.insert(.swap)
            structural.insert(.shuffle)
        }
        if hasSwappableGroup(minimumSize: 3) {
            structural.insert(.move)
        }
        if hasTandemGroup {
            structural.insert(.lockstepDelta)
        }
        if hasTwinGroup {
            structural.insert(.twinSplice)
        }
        if deletableSequenceNodeIDs.isEmpty == false {
            structural.insert(.elementDeletion)
        }
        if duplicable.isEmpty == false {
            structural.insert(.elementDuplication)
        }
        if sites.isEmpty == false {
            structural.insert(.valueReseed)
        }
        if deletableSequenceNodeIDs.isEmpty == false {
            structural.insert(.runDeletion)
        }
        if duplicableSequenceNodeIDs.isEmpty == false {
            structural.insert(.runDuplication)
        }
        if graph.liveNodeIDs.contains(where: { nodeID in
            if case let .sequence(metadata) = graph.nodes[nodeID].kind { return metadata.elementCount >= 2 }
            return false
        }) {
            structural.insert(.runCopy)
            structural.insert(.suffixReseed)
        }
        structuralArms = structural
    }
}

package extension FuzzMutator {
    // MARK: - Sibling-Span Operators

    /// Exchanges two same-shaped sibling spans from one swap-eligible group.
    ///
    /// Returns nil when no group has two or more members or the group's positions do not fit the candidate.
    static func swapSiblingSpans(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: targets.permutationScopes, minimumSize: 2, prng: &prng),
              let slots = positionSlots(of: group, graph: targets.graph, within: candidate.count)
        else {
            return nil
        }
        let firstIndex = Int(prng.next(upperBound: UInt64(slots.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(slots.count - 1)))
        let secondIndex = (firstIndex + offset) % slots.count
        return candidate.swappingSpans(slots[firstIndex].range, slots[secondIndex].range)
    }

    /// Permutes a swap-eligible sibling group with a uniformly random permutation.
    ///
    /// Returns nil when no group qualifies or the drawn permutation is the identity; the identity has probability 1/n! and is a cheap miss rather than a redraw, keeping PRNG consumption fixed per call.
    static func shuffleSiblingSpans(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: targets.permutationScopes, minimumSize: 2, prng: &prng),
              let slots = positionSlots(of: group, graph: targets.graph, within: candidate.count)
        else {
            return nil
        }
        var permutation = Array(slots.indices)
        var index = permutation.count - 1
        while index > 0 {
            let other = Int(prng.next(upperBound: UInt64(index + 1)))
            permutation.swapAt(index, other)
            index -= 1
        }
        guard permutation != Array(slots.indices) else {
            return nil
        }
        return candidate.permutingSpans(ranges: slots.map { $0.range }, permutation: permutation)
    }

    /// Repositions one sibling span within its group, shifting the spans between the source and target slots by one.
    ///
    /// Requires a group of three or more members: within a pair, a move is a swap. Returns nil when no group qualifies or the group's positions do not fit the candidate.
    static func moveSiblingSpan(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickSwappableGroup(scopes: targets.permutationScopes, minimumSize: 3, prng: &prng),
              let slots = positionSlots(of: group, graph: targets.graph, within: candidate.count)
        else {
            return nil
        }
        let source = Int(prng.next(upperBound: UInt64(slots.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(slots.count - 1)))
        let target = (source + offset) % slots.count

        // Rotation permutation: the source span's content lands at the target slot and the spans between them shift one slot toward the source.
        var permutation = Array(slots.indices)
        if source < target {
            for destination in source ..< target {
                permutation[destination] = destination + 1
            }
        } else {
            for destination in (target + 1) ... source {
                permutation[destination] = destination - 1
            }
        }
        permutation[target] = source
        return candidate.permutingSpans(ranges: slots.map { $0.range }, permutation: permutation)
    }

    // MARK: - Lockstep Delta

    /// Shifts every member of one same-tag tandem group by a shared delta in a shared direction.
    ///
    /// The direction is a fair draw and the delta is log-uniform under ``FuzzTunables/lockstepDeltaExponentLimit``, so agreement between the members (equal values, fixed differences) survives the shift.
    ///
    /// All or nothing: a group with one member the delta cannot move is a miss, not a partial shift. Moving a subset breaks the very agreement the operator exists to preserve, and nothing downstream would catch it.
    static func lockstepDelta(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let tandem = targets.tandem,
              let group = pickTandemGroup(tandem, prng: &prng)
        else {
            return nil
        }
        var entries: [(index: Int, entry: ChoiceSequenceValue)] = []
        entries.reserveCapacity(group.leaves.count)
        var headroomUp: UInt64 = .max
        var headroomDown: UInt64 = .max
        for leaf in group.leaves {
            guard let range = targets.graph.nodes[leaf.nodeID].positionRange,
                  range.lowerBound < candidate.count
            else {
                return nil
            }
            let element = candidate[range.lowerBound]
            guard case let .value(value) = element else {
                return nil
            }
            headroomUp = min(headroomUp, value.headroom(upward: true, tag: group.typeTag))
            headroomDown = min(headroomDown, value.headroom(upward: false, tag: group.typeTag))
            entries.append((index: range.lowerBound, entry: element))
        }
        guard entries.count >= 2 else {
            return nil
        }
        guard headroomUp > 0 || headroomDown > 0 else {
            return nil
        }
        let shiftUpward = switch (headroomUp, headroomDown) {
            case (0, _): false
            case (_, 0): true
            default: prng.next(upperBound: 2) == 0
        }
        let maxDelta = shiftUpward ? headroomUp : headroomDown
        let delta = 1 + prng.next(upperBound: maxDelta)
        guard let shifted = candidate.shiftingGroup(
            entries: entries,
            tag: group.typeTag,
            shiftUpward: shiftUpward,
            delta: delta,
            usesFloatingSteps: group.typeTag.isFloatingPoint,
            policy: .requireWholeGroup
        ) else {
            return nil
        }
        return shifted.candidate
    }

    // MARK: - Element Run Operators

    /// A log-uniform run length in `1 ... limit`: 1, 2, 4, and so on up to the largest power of two not above `limit`, each with equal probability, so short runs are the common case and long ones stay reachable.
    private static func runLength(upTo limit: Int, prng: inout Xoshiro256) -> Int {
        guard limit > 1 else {
            return 1
        }
        var powers = 0
        var span = 1
        while span * 2 <= limit {
            span *= 2
            powers += 1
        }
        return 1 << Int(prng.next(upperBound: UInt64(powers + 1)))
    }

    /// Draws one sequence node with at least `minimumElements` elements, uniformly over the eligible nodes, and returns its metadata.
    private static func pickSequenceNode(
        from nodeIDs: [Int],
        graph: ChoiceGraph,
        minimumElements: Int,
        prng: inout Xoshiro256
    ) -> SequenceMetadata? {
        let eligible = nodeIDs.filter { nodeID in
            if case let .sequence(metadata) = graph.nodes[nodeID].kind {
                return metadata.elementCount >= minimumElements && metadata.childPositionRanges.count == metadata.elementCount
            }
            return false
        }
        guard eligible.isEmpty == false else {
            return nil
        }
        guard case let .sequence(metadata) = graph.nodes[eligible[Int(prng.next(upperBound: UInt64(eligible.count)))]].kind else {
            return nil
        }
        return metadata
    }

    /// Removes a run of consecutive elements from one sequence node: the typed form of the medium band's block deletion, cutting on element boundaries so the prefix stays parseable.
    ///
    /// The run length is log-uniform up to what the node's lower length bound allows. Returns nil when no node has a removable run or the run's positions do not fit the candidate.
    static func deleteElementRun(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let metadata = pickSequenceNode(from: targets.deletableSequenceNodeIDs, graph: targets.graph, minimumElements: 1, prng: &prng) else {
            return nil
        }
        let lower = Int(metadata.lengthConstraint?.lowerBound ?? 0)
        let removable = metadata.elementCount - lower
        guard removable >= 1 else {
            return nil
        }
        let length = runLength(upTo: removable, prng: &prng)
        let start = Int(prng.next(upperBound: UInt64(metadata.elementCount - length + 1)))
        let first = metadata.childPositionRanges[start]
        let last = metadata.childPositionRanges[start + length - 1]
        guard last.upperBound < candidate.count else {
            return nil
        }
        var result = candidate
        result.removeSubrange(first.lowerBound ... last.upperBound)
        return result
    }

    /// Repeats a run of consecutive elements of one sequence node in place: the typed form of the medium band's block duplication.
    ///
    /// The copy is inserted directly after the run, so a repeated instruction idiom lands where the blind duplication put it. Returns nil when no node can grow by the drawn run or the run's positions do not fit the candidate.
    static func duplicateElementRun(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let metadata = pickSequenceNode(from: targets.duplicableSequenceNodeIDs, graph: targets.graph, minimumElements: 1, prng: &prng) else {
            return nil
        }
        let upper = metadata.lengthConstraint?.upperBound ?? UInt64.max
        let headroom = upper == UInt64.max ? metadata.elementCount : Int(min(UInt64(metadata.elementCount), upper - UInt64(metadata.elementCount)))
        guard headroom >= 1 else {
            return nil
        }
        let length = runLength(upTo: headroom, prng: &prng)
        let start = Int(prng.next(upperBound: UInt64(metadata.elementCount - length + 1)))
        let first = metadata.childPositionRanges[start]
        let last = metadata.childPositionRanges[start + length - 1]
        guard last.upperBound < candidate.count else {
            return nil
        }
        var result = candidate
        result.insert(contentsOf: candidate[first.lowerBound ... last.upperBound], at: last.upperBound + 1)
        return result
    }

    /// Copies one run of a sequence node over a disjoint run of the same node: the typed form of the medium band's block overwrite, within one sequence.
    ///
    /// Both runs have the drawn length, so the sequence keeps its element count; the target's spans are replaced entry for entry with the source's, which may change the candidate's length when the elements are composites of different sizes. Returns nil when no node has two elements, or the runs do not fit the candidate.
    static func copyElementRun(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        let sequenceNodeIDs = targets.graph.liveNodeIDs.filter { nodeID in
            if case let .sequence(metadata) = targets.graph.nodes[nodeID].kind { return metadata.elementCount >= 2 }
            return false
        }
        guard let metadata = pickSequenceNode(from: sequenceNodeIDs, graph: targets.graph, minimumElements: 2, prng: &prng) else {
            return nil
        }
        let length = runLength(upTo: metadata.elementCount / 2, prng: &prng)
        let starts = metadata.elementCount - length + 1
        let source = Int(prng.next(upperBound: UInt64(starts)))
        // The target is drawn uniformly over the starts whose run is disjoint from the source's, by counting them rather than rejecting: on a three-element list with runs of one there are exactly two, and a rejection loop that gives up leaves the arm missing on the lists where an overwrite matters most.
        let excludedLow = max(0, source - length + 1)
        let excludedHigh = min(starts - 1, source + length - 1)
        let excludedCount = excludedHigh - excludedLow + 1
        let validCount = starts - excludedCount
        guard validCount >= 1 else {
            return nil
        }
        var target = Int(prng.next(upperBound: UInt64(validCount)))
        if target >= excludedLow {
            target += excludedCount
        }
        let sourceRange = metadata.childPositionRanges[source].lowerBound ... metadata.childPositionRanges[source + length - 1].upperBound
        let targetRange = metadata.childPositionRanges[target].lowerBound ... metadata.childPositionRanges[target + length - 1].upperBound
        guard sourceRange.upperBound < candidate.count, targetRange.upperBound < candidate.count else {
            return nil
        }
        return candidate.copyingSpan(from: sourceRange, onto: targetRange)
    }

    /// Cuts one sequence node at an element, dropping every element from there to its end, and reseeds every maximal independent site after the node: the typed form of the high band's region deletion.
    ///
    /// The blind cut dropped a quarter to three quarters of the sequence by index and left the materialiser to regenerate whatever followed from the fallback tree and the PRNG. Here the cut lands on an element boundary and the regeneration is explicit: the sites after the shortened node are reseeded at their own positions in the shortened candidate. Returns nil when no node has at least two elements above its lower length bound, or the cut does not fit the candidate.
    static func suffixReseed(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> (candidate: ChoiceSequence, reseedRanges: [ClosedRange<Int>])? {
        guard let metadata = pickSequenceNode(from: targets.deletableSequenceNodeIDs, graph: targets.graph, minimumElements: 2, prng: &prng) else {
            return nil
        }
        let lower = Int(metadata.lengthConstraint?.lowerBound ?? 0)
        let keepAtLeast = max(lower, 1)
        guard metadata.elementCount > keepAtLeast else {
            return nil
        }
        let cut = keepAtLeast + Int(prng.next(upperBound: UInt64(metadata.elementCount - keepAtLeast)))
        let first = metadata.childPositionRanges[cut]
        let last = metadata.childPositionRanges[metadata.elementCount - 1]
        guard last.upperBound < candidate.count else {
            return nil
        }
        let removed = first.lowerBound ... last.upperBound
        var result = candidate
        result.removeSubrange(removed)
        let shift = removed.count
        var ranges: [ClosedRange<Int>] = []
        for index in targets.maximalReseedSiteIndices {
            let range = targets.reseedSites[index].range
            guard range.lowerBound > removed.upperBound else { continue }
            let shifted = (range.lowerBound - shift) ... (range.upperBound - shift)
            guard shifted.upperBound < result.count else { continue }
            ranges.append(shifted)
        }
        return (result, ranges)
    }

    // MARK: - Sequence Element Operators

    /// Deletes one element from a random sequence node, producing a shorter candidate.
    ///
    /// Returns nil when no sequence node has deletable elements or the chosen element's positions do not fit the candidate.
    static func deleteSequenceElement(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        let eligible = targets.deletableSequenceNodeIDs
        guard eligible.isEmpty == false else {
            return nil
        }
        let nodeID = eligible[Int(prng.next(upperBound: UInt64(eligible.count)))]
        guard case let .sequence(metadata) = targets.graph.nodes[nodeID].kind,
              metadata.childPositionRanges.isEmpty == false
        else {
            return nil
        }
        let elementIndex = Int(prng.next(upperBound: UInt64(metadata.childPositionRanges.count)))
        let range = metadata.childPositionRanges[elementIndex]
        guard range.upperBound < candidate.count else {
            return nil
        }
        var result = candidate
        result.removeSubrange(range.lowerBound ... range.upperBound)
        return result
    }

    /// Duplicates one element from a random sequence node, producing a longer candidate.
    ///
    /// Copies the element's full choice span and inserts it after the last element in the same sequence. Returns nil when no sequence node has elements or the chosen element's positions do not fit the candidate.
    static func duplicateSequenceElement(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        let eligible = targets.duplicableSequenceNodeIDs
        guard eligible.isEmpty == false else {
            return nil
        }
        let nodeID = eligible[Int(prng.next(upperBound: UInt64(eligible.count)))]
        guard case let .sequence(metadata) = targets.graph.nodes[nodeID].kind,
              metadata.childPositionRanges.isEmpty == false
        else {
            return nil
        }
        let elementIndex = Int(prng.next(upperBound: UInt64(metadata.childPositionRanges.count)))
        let sourceRange = metadata.childPositionRanges[elementIndex]
        guard sourceRange.upperBound < candidate.count else {
            return nil
        }
        let lastElementRange = metadata.childPositionRanges[metadata.childPositionRanges.count - 1]
        guard lastElementRange.upperBound < candidate.count else {
            return nil
        }
        var result = candidate
        result.insert(contentsOf: candidate[sourceRange.lowerBound ... sourceRange.upperBound], at: lastElementRange.upperBound + 1)
        return result
    }

    // MARK: - Value Reseed

    /// Chooses the spans a value reseed draws fresh: one, two, or three independent sites weighted by span, or every maximal site, each with equal probability.
    ///
    /// The candidate is left untouched; the materialiser redraws the returned spans at their own sites with the cursor and fallback withheld, so a leaf takes a fresh in-range value and a pick a fresh branch and subtree, while everything outside the spans is read from the parent. Sites are drawn without nesting, so the spans are disjoint. Returns nil when the parent has no site or every span is out of the candidate's bounds.
    static func valueReseed(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> [ClosedRange<Int>]? {
        let sites = targets.reseedSites
        guard sites.isEmpty == false else {
            return nil
        }
        let countDraw = prng.next(upperBound: 4)
        var chosen: [Int] = []
        if countDraw == 3 {
            chosen = targets.maximalReseedSiteIndices
        } else {
            let wanted = Int(countDraw) + 1
            var totalWeight: UInt64 = 0
            for site in sites {
                totalWeight += UInt64(site.range.count)
            }
            // Bounded rejection: a draw nested in or containing a chosen site is discarded, and the loop stops after a fixed number of draws so PRNG consumption stays bounded per call.
            var draws = 0
            while chosen.count < wanted, draws < wanted * 4 {
                draws += 1
                var remaining = prng.next(upperBound: totalWeight)
                var pick = sites.count - 1
                for (index, site) in sites.enumerated() {
                    let weight = UInt64(site.range.count)
                    if remaining < weight {
                        pick = index
                        break
                    }
                    remaining -= weight
                }
                if chosen.contains(pick) { continue }
                if sites[pick].containingSiteIndices.contains(where: { chosen.contains($0) }) { continue }
                if chosen.contains(where: { sites[$0].containingSiteIndices.contains(pick) }) { continue }
                chosen.append(pick)
            }
        }
        var ranges: [ClosedRange<Int>] = []
        ranges.reserveCapacity(chosen.count)
        for index in chosen.sorted() {
            let range = sites[index].range
            guard range.upperBound < candidate.count else { continue }
            ranges.append(range)
        }
        return ranges.isEmpty ? nil : ranges
    }

    // MARK: - Twin Detection

    /// Discriminates zip children the generator drew from the same site, so twin spans can be spliced onto one another.
    ///
    /// Picks and binds match by their site fingerprint. Sequences match by element type tag rather than shape, so twins of different lengths (two instruction lists) still group. Leaves match by type tag, zips by child count.
    internal enum TwinKey: Hashable {
        case pick(UInt64)
        case bind(UInt64)
        case value(TypeTag)
        case elementSequence(TypeTag)
        case zip(childCount: Int)
    }

    /// Computes the twin-span groups of every zip node: position ranges of siblings sharing a twin key, in position order, groups ordered by first position.
    ///
    /// Group and member ordering is explicit rather than dictionary order so seeded runs replay identically across processes.
    internal static func twinSpanGroups(graph: ChoiceGraph) -> [[ClosedRange<Int>]] {
        var groups: [[ClosedRange<Int>]] = []
        for nodeID in graph.liveNodeIDs {
            let node = graph.nodes[nodeID]
            guard case .zip = node.kind, node.children.count >= 2 else {
                continue
            }
            var rangesByKey: [TwinKey: [ClosedRange<Int>]] = [:]
            for childID in node.children {
                let child = graph.nodes[childID]
                guard let range = child.positionRange else {
                    continue
                }
                if child.scopeAnnotation.isDepthControl || child.scopeAnnotation.isLaneControl {
                    continue
                }
                guard let key = twinKey(of: child) else {
                    continue
                }
                rangesByKey[key, default: []].append(range)
            }
            let zipGroups = rangesByKey.values
                .filter { $0.count >= 2 }
                .map { $0.sorted { $0.lowerBound < $1.lowerBound } }
                .sorted { $0[0].lowerBound < $1[0].lowerBound }
            groups.append(contentsOf: zipGroups)
        }
        return groups
    }

    /// The twin key of one zip child, or nil for kinds with no twin identity (`just`, untagged sequences).
    internal static func twinKey(of node: ChoiceGraphNode) -> TwinKey? {
        switch node.kind {
            case let .pick(metadata):
                .pick(metadata.fingerprint)
            case let .bind(metadata):
                .bind(metadata.fingerprint)
            case let .chooseBits(metadata):
                .value(metadata.typeTag)
            case let .sequence(metadata):
                metadata.elementTypeTag.map { .elementSequence($0) }
            case let .zip(metadata):
                metadata.isOpaque ? nil : .zip(childCount: node.children.count)
            case .just:
                nil
        }
    }

    // MARK: - Twin Splice

    /// Copies one twin span over a sibling twin span, creating structural agreement between them.
    ///
    /// The one-directional counterpart of ``swapSiblingSpans(_:targets:prng:)``: after the splice both spans hold the source content. Twin spans of different lengths shift the positions after the target; guided materialization absorbs the drift. Returns nil when the entry has no twin group or a chosen span does not fit the candidate.
    static func twinSplice(
        _ candidate: ChoiceSequence,
        targets: MutationTargets,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        guard let group = pickRangeGroup(targets.twinSpanGroups, prng: &prng) else {
            return nil
        }
        let sourceIndex = Int(prng.next(upperBound: UInt64(group.count)))
        let offset = 1 + Int(prng.next(upperBound: UInt64(group.count - 1)))
        let targetIndex = (sourceIndex + offset) % group.count
        let source = group[sourceIndex]
        let target = group[targetIndex]
        guard source.upperBound < candidate.count, target.upperBound < candidate.count else {
            return nil
        }
        return candidate.copyingSpan(from: source, onto: target)
    }

    // MARK: - Typed Crossover

    /// Replaces one pick subtree with a same-fingerprint span from a different corpus entry.
    ///
    /// The donor span is an admission-time fact about the donor's immutable sequence, so it always addresses the donor validly; only the recipient's target range is bounds-checked against the candidate. A drawn donor from the recipient's own entry is a cheap miss rather than a redraw, keeping PRNG consumption fixed per call. Returns nil when no fingerprint has both an active recipient pick and a donor row.
    static func typedCrossover(
        _ candidate: ChoiceSequence,
        parentHash: UInt64,
        targets: MutationTargets,
        corpus: FuzzCorpus,
        prng: inout Xoshiro256
    ) -> ChoiceSequence? {
        // Fingerprint order is explicit rather than dictionary order so seeded runs replay identically across processes.
        var eligible: [(fingerprint: UInt64, recipients: [Int])] = []
        var totalWeight: UInt64 = 0
        for fingerprint in targets.sortedFingerprints {
            guard let recipients = targets.graph.selfSimilarityGroups[fingerprint],
                  recipients.isEmpty == false,
                  let donors = corpus.donorSpansByFingerprint[fingerprint],
                  donors.isEmpty == false
            else {
                continue
            }
            eligible.append((fingerprint: fingerprint, recipients: recipients))
            totalWeight += UInt64(recipients.count)
        }
        guard totalWeight > 0 else {
            return nil
        }

        var remaining = prng.next(upperBound: totalWeight)
        var chosen = eligible[eligible.count - 1]
        for entry in eligible {
            let weight = UInt64(entry.recipients.count)
            if remaining < weight {
                chosen = entry
                break
            }
            remaining -= weight
        }

        let targetNodeID = chosen.recipients[Int(prng.next(upperBound: UInt64(chosen.recipients.count)))]
        guard let donors = corpus.donorSpansByFingerprint[chosen.fingerprint] else {
            return nil
        }
        let donor = donors[Int(prng.next(upperBound: UInt64(donors.count)))]
        guard let target = targets.graph.nodes[targetNodeID].positionRange,
              target.upperBound < candidate.count,
              corpus.entries[donor.entryIndex].hash != parentHash
        else {
            return nil
        }
        let donorSequence = corpus.entries[donor.entryIndex].sequence
        if let donorGraph = corpus.entries[donor.entryIndex].mutationTargets?.graph,
           donorGraph.selfSimilarityGroups[chosen.fingerprint] != nil
        {
            let donorEntries = Array(donorSequence[donor.range.lowerBound ... donor.range.upperBound])
            let expanded = GraphStructuralEncoder.expandDepthZeroLeaves(
                donorEntries,
                donorNodeID: donor.donorNodeID,
                donorRangeStart: donor.range.lowerBound,
                graph: donorGraph
            )
            var result = candidate
            result.replaceSubrange(target.lowerBound ... target.upperBound, with: expanded)
            return result
        }
        return candidate.graftingSpan(
            from: donorSequence,
            at: donor.range,
            onto: target
        )
    }

    // MARK: - Scope Selection

    /// Picks one swap-eligible sibling group with `minimumSize` or more members, weighted by member count.
    private static func pickSwappableGroup(
        scopes: [PermutationScope],
        minimumSize: Int,
        prng: inout Xoshiro256
    ) -> [Int]? {
        var totalWeight: UInt64 = 0
        for scope in scopes {
            for group in scope.swappableGroups where group.count >= minimumSize {
                totalWeight += UInt64(group.count)
            }
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        var last: [Int]?
        for scope in scopes {
            for group in scope.swappableGroups where group.count >= minimumSize {
                let weight = UInt64(group.count)
                if remaining < weight {
                    return group
                }
                remaining -= weight
                last = group
            }
        }
        return last
    }

    /// Picks one range group with two or more members, weighted by member count.
    private static func pickRangeGroup(
        _ groups: [[ClosedRange<Int>]],
        prng: inout Xoshiro256
    ) -> [ClosedRange<Int>]? {
        var totalWeight: UInt64 = 0
        for group in groups where group.count >= 2 {
            totalWeight += UInt64(group.count)
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        var last: [ClosedRange<Int>]?
        for group in groups where group.count >= 2 {
            let weight = UInt64(group.count)
            if remaining < weight {
                return group
            }
            remaining -= weight
            last = group
        }
        return last
    }

    /// Picks one tandem group with two or more leaves, weighted by leaf count.
    private static func pickTandemGroup(
        _ scope: TandemScope,
        prng: inout Xoshiro256
    ) -> TandemGroup? {
        var totalWeight: UInt64 = 0
        for group in scope.groups where group.leaves.count >= 2 {
            totalWeight += UInt64(group.leaves.count)
        }
        guard totalWeight > 0 else {
            return nil
        }
        var remaining = prng.next(upperBound: totalWeight)
        var last: TandemGroup?
        for group in scope.groups where group.leaves.count >= 2 {
            let weight = UInt64(group.leaves.count)
            if remaining < weight {
                return group
            }
            remaining -= weight
            last = group
        }
        return last
    }

    /// Resolves a sibling group's node IDs to position ranges sorted by position, or nil when any member is inactive or extends past the candidate.
    private static func positionSlots(
        of group: [Int],
        graph: ChoiceGraph,
        within count: Int
    ) -> [(nodeID: Int, range: ClosedRange<Int>)]? {
        var slots: [(nodeID: Int, range: ClosedRange<Int>)] = []
        slots.reserveCapacity(group.count)
        for nodeID in group {
            guard let range = graph.nodes[nodeID].positionRange, range.upperBound < count else {
                return nil
            }
            slots.append((nodeID: nodeID, range: range))
        }
        slots.sort { $0.range.lowerBound < $1.range.lowerBound }
        return slots
    }
}
