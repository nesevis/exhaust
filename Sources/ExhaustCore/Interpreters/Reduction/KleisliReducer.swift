//
//  KleisliReducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

// MARK: - Academic Provenance

//
// Kleisli reducer: principled test case reduction via cyclic coordinate descent over
// bind depths in the generator's Kleisli chain (Sepulveda-Jimenez, "Categories of
// Optimization Reductions", 2026).
//
// Each bind depth is a coordinate axis. Shrink tactics form a dominance lattice
// (2-cells) enabling principled pruning. Each step is a certified reduction morphism
// (enc = mutate sequence, dec = GuidedMaterializer re-materialize).
//
// Guarantees: termination (well-founded shortlex), correctness (feasibility preservation),
// compositionality, coordinate-wise minimum at fixed point.
//

import Foundation

// MARK: - Reducer Dispatch

public extension Interpreters {
    /// Dispatches to either the Kleisli reducer or the standard reducer based on the `useKleisli` flag.
    static func dispatchReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: TCRConfiguration,
        useKleisli: Bool,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        if true || useKleisli {
            return try kleisliReduce(gen: gen, tree: tree, config: .init(from: config), property: property)
        } else {
            return try reduce(gen: gen, tree: tree, config: config, property: property)
        }
    }
}

// MARK: - Configuration

public extension Interpreters {
    /// Configuration for the ``KleisliReducer``.
    struct KleisliReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        let maxStalls: Int
        /// Window size for cycle detection.
        let recentCycleWindow: Int
        /// Per-strategy probe budgets.
        let probeBudgets: TCRConfiguration.ProbeBudgets
        /// Beam search tuning for aligned deletion.
        let alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning

        private init(
            maxStalls: Int,
            recentCycleWindow: Int,
            probeBudgets: TCRConfiguration.ProbeBudgets,
            alignedDeletionBeamSearchTuning: TCRConfiguration.AlignedDeletionBeamSearchTuning,
        ) {
            self.maxStalls = maxStalls
            self.recentCycleWindow = recentCycleWindow
            self.probeBudgets = probeBudgets
            self.alignedDeletionBeamSearchTuning = alignedDeletionBeamSearchTuning
        }

        /// Maps a ``TCRConfiguration`` preset to the corresponding Kleisli configuration.
        init(from config: TCRConfiguration) {
            switch config {
            case .fast:
                self = .fast
            case .slow:
                self = .slow
            }
        }

        static let fast = Self(
            maxStalls: 3,
            recentCycleWindow: 6,
            probeBudgets: .fast,
            alignedDeletionBeamSearchTuning: .fast,
        )

        static let slow = Self(
            maxStalls: 8,
            recentCycleWindow: 12,
            probeBudgets: .slow,
            alignedDeletionBeamSearchTuning: .slow,
        )
    }
}

// MARK: - Entry Point

public extension Interpreters {
    /// Kleisli reducer: cyclic coordinate descent over bind depths.
    ///
    /// Coexists with the existing ``reduce(gen:tree:config:property:)`` reducer.
    /// The key structural difference is that bind depths are the primary iteration axis,
    /// with tactics ordered by a dominance lattice within each depth.
    static func kleisliReduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: KleisliReducerConfiguration,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        var currentSequence = ChoiceSequence.flatten(tree)
        var currentTree = tree
        guard var currentOutput = try materialize(gen, with: tree, using: currentSequence) else {
            return nil
        }

        var stallBudget = config.maxStalls
        var rejectCache = ReducerCache()
        var spanCache = KleisliSpanCache()
        let hasBind = tree.containsBind
        var bindSpanIndex: BindSpanIndex? = hasBind ? BindSpanIndex(from: currentSequence) : nil
        var recentSequences = [currentSequence]
        var bestSequence = currentSequence
        var bestOutput = currentOutput
        var loops = 0
        var fallbackTree: ChoiceTree? = hasBind ? currentTree : nil

        let budgetLogger: ((String) -> Void)? = isInstrumented ? { message in
            ExhaustLog.notice(
                category: .reducer,
                event: "kleisli_probe_budget_exhausted",
                message,
            )
        } : nil

        // Build tactic lattices
        let branchTactics = KleisliReducer.buildBranchTactics()
        let containerLattice = KleisliReducer.buildContainerLattice(config: config, budgetLogger: budgetLogger)
        let numericLattice = KleisliReducer.buildNumericLattice()
        let floatLattice = KleisliReducer.buildFloatLattice()
        let orderingTactics = KleisliReducer.buildOrderingTactics()
        let crossStageTactics = KleisliReducer.buildCrossStageTactics(config: config, budgetLogger: budgetLogger)

        // Helper: accept a successful tactic result and update all mutable state.
        //
        // For non-bind generators, also tracks the global best (shortlex-smallest)
        // sequence seen. For bind generators, full-sequence shortlex comparison is
        // meaningless because bound values are re-derived from inner values — a
        // shortlex-smaller sequence can produce a worse output. Instead, the current
        // state is always considered the best (tactics are monotonic within a cycle).
        func accept(
            _ result: ShrinkResult<Output>,
            _ sequence: inout ChoiceSequence,
            _ tree: inout ChoiceTree,
            _ output: inout Output,
            _ cache: inout KleisliSpanCache,
            _ hasBind: Bool,
            _ bindIdx: inout BindSpanIndex?,
        ) {
            sequence = result.sequence
            tree = result.tree
            output = result.output
            cache.invalidate()
            if hasBind {
                bindIdx = BindSpanIndex(from: sequence)
                fallbackTree = tree
                // For bind generators, always update best to current — shortlex
                // on the full sequence doesn't capture output quality.
                bestSequence = sequence
                bestOutput = output
            } else {
                if sequence.shortLexPrecedes(bestSequence) {
                    bestSequence = sequence
                    bestOutput = output
                }
            }
        }

        // Helper: log a tactic success.
        func logTactic(_ name: String, depth: Int, evaluations: Int? = nil) {
            var metadata: [String: String] = ["tactic": name, "depth": "\(depth)"]
            if let evaluations { metadata["evaluations"] = "\(evaluations)" }
            ExhaustLog.debug(
                category: .reducer,
                event: "kleisli_tactic_succeeded",
                metadata: metadata,
            )
        }

        while stallBudget > 0 {
            loops += 1
            var improved = false

            let maxBindDepth = bindSpanIndex?.maxBindDepth ?? 0

            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "kleisli_cycle_start",
                    metadata: [
                        "loop": "\(loops)",
                        "stall_budget": "\(stallBudget)",
                        "sequence": currentSequence.shortString,
                        "max_bind_depth": "\(maxBindDepth)",
                    ],
                )
            }

            // ── Phase 1: Global structural tactics (branch manipulation) ──
            // These can change generator/tree shape at any depth, so they run
            // once per cycle, not per-depth.
            let globalContext = TacticContext(bindIndex: bindSpanIndex, depth: -1, fallbackTree: fallbackTree)
            for branchTactic in branchTactics {
                if let result = try branchTactic.apply(
                    gen: gen,
                    sequence: currentSequence,
                    tree: currentTree,
                    context: globalContext,
                    property: property,
                    rejectCache: &rejectCache,
                ) {
                    accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                    improved = true
                    if isInstrumented { logTactic(branchTactic.name, depth: -1) }
                }
            }

            // ── Phase 2: Per-coordinate descent ──
            // After any tactic succeeds, spans are stale — break out and let the
            // outer cycle restart with fresh span extraction.
            depthLoop: for depth in stride(from: maxBindDepth, through: 0, by: -1) {
                let depthContext = TacticContext(bindIndex: bindSpanIndex, depth: depth, fallbackTree: fallbackTree)

                // Filter spans to this bind depth
                let allValueSpans = spanCache.getAllValueSpans(from: currentSequence)
                let depthValueSpans: [ChoiceSpan]
                if let bi = bindSpanIndex {
                    depthValueSpans = allValueSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                } else {
                    depthValueSpans = allValueSpans
                }

                let depthFloatSpans = depthValueSpans.filter { span in
                    guard let v = currentSequence[span.range.lowerBound].value else { return false }
                    return v.choice.tag == .double || v.choice.tag == .float
                }

                let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)

                // Phase 2a: Deletion tactics with span routing
                var containerTraversal = containerLattice.orderedTraversal()
                while let entry = containerTraversal.next() {
                    // Route the right spans to the right tactic based on span category
                    let targetSpans: [ChoiceSpan]
                    switch entry.spanCategory {
                    case .containerSpans:
                        let containerSpans = spanCache.getContainerSpans(from: currentSequence)
                        if let bi = bindSpanIndex {
                            targetSpans = containerSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                        } else {
                            targetSpans = containerSpans
                        }
                    case .sequenceElements:
                        let seqElementSpans = spanCache.getSequenceElementSpans(from: currentSequence)
                        if let bi = bindSpanIndex {
                            targetSpans = seqElementSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                        } else {
                            targetSpans = seqElementSpans
                        }
                    case .sequenceBoundaries:
                        let seqBoundarySpans = spanCache.getSequenceBoundarySpans(from: currentSequence)
                        if let bi = bindSpanIndex {
                            targetSpans = seqBoundarySpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                        } else {
                            targetSpans = seqBoundarySpans
                        }
                    case .freeStandingValues:
                        let freeValueSpans = spanCache.getFreeStandingValueSpans(from: currentSequence)
                        if let bi = bindSpanIndex {
                            targetSpans = freeValueSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                        } else {
                            targetSpans = freeValueSpans
                        }
                    case .siblingGroups, .mixed:
                        let containerSpans = spanCache.getContainerSpans(from: currentSequence)
                        if let bi = bindSpanIndex {
                            targetSpans = containerSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                        } else {
                            targetSpans = containerSpans
                        }
                    }

                    guard targetSpans.isEmpty == false else { continue }
                    if let result = try entry.tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        targetSpans: targetSpans,
                        context: depthContext,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(entry.tactic.name, depth: depth, evaluations: result.evaluations) }
                        break depthLoop
                    }
                }

                // Phase 2b: Numeric value tactics
                var numericTraversal = numericLattice.orderedTraversal()
                while let tactic = numericTraversal.next() {
                    guard depthValueSpans.isEmpty == false else { break }
                    if let result = try tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        targetSpans: depthValueSpans,
                        context: depthContext,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(tactic.name, depth: depth, evaluations: result.evaluations) }
                        break depthLoop
                    }
                }

                // Phase 2b (cont.): Float value tactics
                var floatTraversal = floatLattice.orderedTraversal()
                while let tactic = floatTraversal.next() {
                    guard depthFloatSpans.isEmpty == false else { break }
                    if let result = try tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        targetSpans: depthFloatSpans,
                        context: depthContext,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(tactic.name, depth: depth, evaluations: result.evaluations) }
                        break depthLoop
                    }
                }

                // Phase 2c: Ordering (siblings at this depth)
                for tactic in orderingTactics {
                    guard siblingGroups.isEmpty == false else { break }
                    if let result = try tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        siblingGroups: siblingGroups,
                        context: depthContext,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(tactic.name, depth: depth) }
                        break depthLoop
                    }
                }
            } // End per-depth loop

            // ── Phase 3: Cross-stage tactics ──
            // Only run when depth-level tactics made no progress, to prevent
            // ping-pong between depth-0 and cross-stage tactics.
            if improved == false {
                let crossStageContext = TacticContext(bindIndex: bindSpanIndex, depth: -1, fallbackTree: fallbackTree)
                let allValueSpans = spanCache.getAllValueSpans(from: currentSequence)
                let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)
                for tactic in crossStageTactics {
                    if let result = try tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        siblingGroups: siblingGroups,
                        allValueSpans: allValueSpans,
                        context: crossStageContext,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(tactic.name, depth: -1) }
                        break // restart cycle with fresh spans
                    }
                }
            }

            // ── Cycle termination logic ──
            if improved {
                let recentWindow = recentSequences.suffix(config.recentCycleWindow)
                if recentWindow.contains(currentSequence) {
                    if isInstrumented {
                        ExhaustLog.notice(
                            category: .reducer,
                            event: "kleisli_cycle_detected",
                            metadata: ["window": "\(config.recentCycleWindow)"],
                        )
                    }
                    break
                }

                recentSequences.append(currentSequence)
                let maxHistory = max(config.recentCycleWindow * 2, config.recentCycleWindow + 1)
                if recentSequences.count > maxHistory {
                    recentSequences.removeFirst(recentSequences.count - maxHistory)
                }
                stallBudget = config.maxStalls
                continue
            }

            // No improvement — if the tree has binds, try re-deriving via GuidedMaterializer
            // to get consistent (sequence, tree) state for the next cycle.
            if hasBind {
                let seed = currentSequence.zobristHash
                if case let .success(value, seq, newTree) =
                    GuidedMaterializer.materialize(gen, prefix: currentSequence, seed: seed, fallbackTree: fallbackTree ?? currentTree),
                   property(value) == false
                {
                    // Merge shortlex-smaller bound entries from old sequence
                    var mergedSeq = seq
                    var didMerge = false
                    if let bi = bindSpanIndex {
                        let newBi = BindSpanIndex(from: seq)
                        for (oldRegion, newRegion) in zip(bi.regions, newBi.regions) {
                            for (oldIdx, newIdx) in zip(oldRegion.boundRange, newRegion.boundRange) {
                                if currentSequence[oldIdx].shortLexCompare(seq[newIdx]) == .lt {
                                    mergedSeq[newIdx] = currentSequence[oldIdx]
                                    didMerge = true
                                }
                            }
                        }
                    }

                    let finalSeq: ChoiceSequence
                    let finalOutput: Output
                    if didMerge, mergedSeq.shortLexPrecedes(seq),
                       let mergedResult = try? materialize(gen, with: newTree, using: mergedSeq),
                       property(mergedResult) == false
                    {
                        finalSeq = mergedSeq
                        finalOutput = mergedResult
                    } else {
                        finalSeq = seq
                        finalOutput = value
                    }

                    // Only skip stall decrement if re-derivation actually changed the sequence
                    if finalSeq != currentSequence {
                        currentSequence = finalSeq
                        currentOutput = finalOutput
                        currentTree = newTree
                        bindSpanIndex = BindSpanIndex(from: currentSequence)
                        spanCache.invalidate()
                        rejectCache = ReducerCache()
                        // For bind generators, always update best (shortlex on full
                        // sequence is unreliable). For non-bind, use shortlex guard.
                        if hasBind || currentSequence.shortLexPrecedes(bestSequence) {
                            bestSequence = currentSequence
                            bestOutput = currentOutput
                        }
                        continue
                    }
                }
            }

            stallBudget -= 1
        }

        if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "kleisli_stalled",
                metadata: [
                    "loops": "\(loops)",
                ],
            )
        }

        return (bestSequence, bestOutput)
    }
}

// MARK: - Span Cache

private struct KleisliSpanCache {
    private var allValueSpans: [ChoiceSpan]?
    private var containerSpans: [ChoiceSpan]?
    private var sequenceElementSpans: [ChoiceSpan]?
    private var sequenceBoundarySpans: [ChoiceSpan]?
    private var freeStandingValueSpans: [ChoiceSpan]?
    private var siblingGroups: [SiblingGroup]?

    mutating func invalidate() {
        allValueSpans = nil
        containerSpans = nil
        sequenceElementSpans = nil
        sequenceBoundarySpans = nil
        freeStandingValueSpans = nil
        siblingGroups = nil
    }

    mutating func getAllValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = allValueSpans { return cached }
        let spans = ChoiceSequence.extractAllValueSpans(from: sequence)
        allValueSpans = spans
        return spans
    }

    mutating func getContainerSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = containerSpans { return cached }
        let spans = ChoiceSequence.extractContainerSpans(from: sequence)
        containerSpans = spans
        return spans
    }

    mutating func getSequenceElementSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = sequenceElementSpans { return cached }
        let spans = ChoiceSequence.extractSequenceElementSpans(from: sequence)
        sequenceElementSpans = spans
        return spans
    }

    mutating func getSequenceBoundarySpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = sequenceBoundarySpans { return cached }
        let spans = ChoiceSequence.extractSequenceBoundarySpans(from: sequence)
        sequenceBoundarySpans = spans
        return spans
    }

    mutating func getFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
        if let cached = freeStandingValueSpans { return cached }
        let spans = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
        freeStandingValueSpans = spans
        return spans
    }

    mutating func getSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
        if let cached = siblingGroups { return cached }
        let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
        siblingGroups = groups
        return groups
    }
}

// MARK: - Tactic Lattice Construction

/// Namespace for ``KleisliReducer`` tactic construction.
enum KleisliReducer {

    // MARK: Branch Tactics

    static func buildBranchTactics() -> [any BranchShrinkTactic] {
        [
            PromoteBranchesTactic(),
            PivotBranchesTactic(),
        ]
    }

    // MARK: Container / Deletion Lattice

    /// 6-node deletion lattice with span-category routing:
    /// ```
    /// [0] DeleteContainerSpans     → dominates [4, 5]
    /// [1] DeleteSequenceElements   → dominates [3, 5]
    /// [2] DeleteSequenceBoundaries → dominates [5]
    /// [3] DeleteFreeStandingValues → dominates [5]
    /// [4] DeleteAlignedWindows     → dominates [5]
    /// [5] SpeculativeDeleteAndRepair → dominates []
    /// ```
    static func buildContainerLattice(
        config: Interpreters.KleisliReducerConfiguration,
        budgetLogger: ((String) -> Void)?,
    ) -> TacticLattice<DeletionTacticEntry> {
        TacticLattice(nodes: [
            .init(
                tactic: DeletionTacticEntry(tactic: DeleteContainerSpansTactic(), spanCategory: .containerSpans),
                dominates: [4, 5]
            ),
            .init(
                tactic: DeletionTacticEntry(tactic: DeleteSequenceElementsTactic(), spanCategory: .sequenceElements),
                dominates: [3, 5]
            ),
            .init(
                tactic: DeletionTacticEntry(tactic: DeleteSequenceBoundariesTactic(), spanCategory: .sequenceBoundaries),
                dominates: [5]
            ),
            .init(
                tactic: DeletionTacticEntry(tactic: DeleteFreeStandingValuesTactic(), spanCategory: .freeStandingValues),
                dominates: [5]
            ),
            .init(
                tactic: DeletionTacticEntry(
                    tactic: DeleteAlignedWindowsTactic(
                        probeBudget: config.probeBudgets.deleteAlignedSiblingWindows,
                        subsetBeamSearchTuning: config.alignedDeletionBeamSearchTuning,
                        onBudgetExhausted: budgetLogger
                    ),
                    spanCategory: .mixed
                ),
                dominates: [5]
            ),
            .init(
                tactic: DeletionTacticEntry(tactic: SpeculativeDeleteTactic(), spanCategory: .mixed),
                dominates: []
            ),
        ])
    }

    // MARK: Numeric Lattice

    /// ```
    /// ZeroValue → BinarySearchToZero → BinarySearchToTarget
    /// ```
    static func buildNumericLattice() -> TacticLattice<any ShrinkTactic> {
        TacticLattice(nodes: [
            .init(tactic: ZeroValueTactic(), dominates: [1, 2]),
            .init(tactic: BinarySearchToZeroTactic(), dominates: [2]),
            .init(tactic: BinarySearchToTargetTactic(), dominates: []),
        ])
    }

    // MARK: Float Lattice

    /// ```
    /// ReduceFloat (4-stage pipeline)
    /// ```
    static func buildFloatLattice() -> TacticLattice<any ShrinkTactic> {
        TacticLattice(nodes: [
            .init(tactic: ReduceFloatTactic(), dominates: []),
        ])
    }

    // MARK: Ordering Tactics

    static func buildOrderingTactics() -> [any SiblingGroupShrinkTactic] {
        [
            ReorderSiblingsTactic(),
        ]
    }

    // MARK: Cross-Stage Tactics

    static func buildCrossStageTactics(
        config: Interpreters.KleisliReducerConfiguration,
        budgetLogger: ((String) -> Void)?,
    ) -> [any CrossStageShrinkTactic] {
        [
            ReduceInTandemTactic(
                probeBudget: config.probeBudgets.reduceValuesInTandem,
                onBudgetExhausted: budgetLogger
            ),
            RedistributeTactic(
                probeBudget: config.probeBudgets.redistributeNumericPairs,
                onBudgetExhausted: budgetLogger
            ),
        ]
    }
}


