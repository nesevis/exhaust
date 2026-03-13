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
        if useKleisli {
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
        var loops = 0

        // Build tactic lattices
        let branchTactics = KleisliReducer.buildBranchTactics()
        let containerLattice = KleisliReducer.buildContainerLattice()
        let numericLattice = KleisliReducer.buildNumericLattice()
        let floatLattice = KleisliReducer.buildFloatLattice()
        let orderingTactics = KleisliReducer.buildOrderingTactics()
        let crossStageTactics = KleisliReducer.buildCrossStageTactics(config: config)

        let budgetLogger: ((String) -> Void)? = isInstrumented ? { message in
            ExhaustLog.notice(
                category: .reducer,
                event: "kleisli_probe_budget_exhausted",
                message,
            )
        } : nil
        _ = budgetLogger // suppress unused warning until Phase 2+

        // Helper: accept a successful tactic result and update all mutable state.
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
            if hasBind { bindIdx = BindSpanIndex(from: sequence) }
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
            for branchTactic in branchTactics {
                if let result = try branchTactic.apply(
                    gen: gen,
                    sequence: currentSequence,
                    tree: currentTree,
                    bindIndex: bindSpanIndex,
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
            depthLoop: for depth in 0 ... maxBindDepth {
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

                let containerSpans = spanCache.getContainerSpans(from: currentSequence)
                let depthContainerSpans: [ChoiceSpan]
                if let bi = bindSpanIndex {
                    depthContainerSpans = containerSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == depth }
                } else {
                    depthContainerSpans = containerSpans
                }

                let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)

                // Phase 2a: Deletion tactics (containers at this depth)
                var containerTraversal = containerLattice.orderedTraversal()
                while let tactic = containerTraversal.next() {
                    guard depthContainerSpans.isEmpty == false else { continue }
                    if let result = try tactic.apply(
                        gen: gen,
                        sequence: currentSequence,
                        tree: currentTree,
                        targetSpans: depthContainerSpans,
                        bindIndex: bindSpanIndex,
                        property: property,
                        rejectCache: &rejectCache,
                    ) {
                        accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                        improved = true
                        if isInstrumented { logTactic(tactic.name, depth: depth, evaluations: result.evaluations) }
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
                        bindIndex: bindSpanIndex,
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
                        bindIndex: bindSpanIndex,
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
                        bindIndex: bindSpanIndex,
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
            let allValueSpans = spanCache.getAllValueSpans(from: currentSequence)
            let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)
            for tactic in crossStageTactics {
                if let result = try tactic.apply(
                    gen: gen,
                    sequence: currentSequence,
                    tree: currentTree,
                    siblingGroups: siblingGroups,
                    allValueSpans: allValueSpans,
                    bindIndex: bindSpanIndex,
                    property: property,
                    rejectCache: &rejectCache,
                ) {
                    accept(result, &currentSequence, &currentTree, &currentOutput, &spanCache, hasBind, &bindSpanIndex)
                    improved = true
                    if isInstrumented { logTactic(tactic.name, depth: -1) }
                    break // restart cycle with fresh spans
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
                    GuidedMaterializer.materialize(gen, prefix: currentSequence, seed: seed, fallbackTree: currentTree),
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

        return (currentSequence, currentOutput)
    }
}

// MARK: - Span Cache

private struct KleisliSpanCache {
    private var allValueSpans: [ChoiceSpan]?
    private var containerSpans: [ChoiceSpan]?
    private var siblingGroups: [SiblingGroup]?

    mutating func invalidate() {
        allValueSpans = nil
        containerSpans = nil
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

    mutating func getSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
        if let cached = siblingGroups { return cached }
        let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
        siblingGroups = groups
        return groups
    }
}

// MARK: - Cross-Stage Tactic Protocol

/// A tactic that operates across all bind depths (tandem, redistribute).
protocol CrossStageShrinkTactic {
    var name: String { get }

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        allValueSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>?
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

    /// ```
    /// DeleteSpans → DeleteAlignedWindows → { ReorderSiblings | SpeculativeDeleteAndRepair }
    /// ```
    static func buildContainerLattice() -> TacticLattice<any ShrinkTactic> {
        TacticLattice(nodes: [
            .init(tactic: DeleteSpansTactic(), dominates: [1, 2]),
            .init(tactic: DeleteAlignedWindowsTactic(), dominates: []),
            .init(tactic: SpeculativeDeleteTactic(), dominates: []),
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

    static func buildCrossStageTactics(config: Interpreters.KleisliReducerConfiguration) -> [any CrossStageShrinkTactic] {
        [
            ReduceInTandemTactic(probeBudget: config.probeBudgets.reduceValuesInTandem),
            RedistributeTactic(probeBudget: config.probeBudgets.redistributeNumericPairs),
        ]
    }
}

// MARK: - Stub Tactics (Phase 1: delegate to existing ReducerStrategies)

// Each stub wraps an existing ReducerStrategies static method as a ShrinkTactic conformance.
// Phase 2+ will replace these with proper implementations.

// MARK: Branch Stubs

private struct PromoteBranchesTactic: BranchShrinkTactic {
    let name = "promoteBranches"
    let applicability = TacticApplicability.branches

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newTree, newSequence, output) = try ReducerStrategies.promoteBranches(
            gen, tree: tree, property: property, sequence: sequence, rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
    }
}

private struct PivotBranchesTactic: BranchShrinkTactic {
    let name = "pivotBranches"
    let applicability = TacticApplicability.branches

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newTree, newSequence, output) = try ReducerStrategies.pivotBranches(
            gen, tree: tree, property: property, sequence: sequence, rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
    }
}

// MARK: Container Stubs

private struct DeleteSpansTactic: ShrinkTactic {
    let name = "deleteSpans"
    let applicability = TacticApplicability.containers

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(
            gen, tree: tree, property: property, sequence: sequence, spans: targetSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        // Re-derive tree via GuidedMaterializer for consistency
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

private struct DeleteAlignedWindowsTactic: ShrinkTactic {
    let name = "deleteAlignedWindows"
    let applicability = TacticApplicability.containers

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        // Aligned window deletion needs sibling groups, not raw spans
        let siblingGroups = ChoiceSequence.extractSiblingGroups(from: sequence)
        guard siblingGroups.isEmpty == false else { return nil }

        guard let (newSequence, output) = try ReducerStrategies.deleteAlignedSiblingWindows(
            gen, tree: tree, property: property, sequence: sequence, siblingGroups: siblingGroups,
            rejectCache: &rejectCache,
            probeBudget: 400,
            subsetBeamSearchTuning: .fast,
            bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

private struct SpeculativeDeleteTactic: ShrinkTactic {
    let name = "speculativeDeleteAndRepair"
    let applicability = TacticApplicability.containers

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        let freeValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
        let deletableSpans = freeValueSpans + targetSpans
        guard deletableSpans.isEmpty == false else { return nil }

        guard let (newSequence, output) = try ReducerStrategies.speculativeDeleteAndRepair(
            gen, tree: tree, property: property, sequence: sequence, spans: deletableSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

// MARK: Numeric Stubs

private struct ZeroValueTactic: ShrinkTactic {
    let name = "zeroValue"
    let applicability = TacticApplicability.numericValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.naiveSimplifyValues(
            gen, tree: tree, property: property, sequence: sequence, valueSpans: targetSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

private struct BinarySearchToZeroTactic: ShrinkTactic {
    let name = "binarySearchToZero"
    let applicability = TacticApplicability.numericValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.simplifyValues(
            gen, tree: tree, property: property, sequence: sequence, valueSpans: targetSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

private struct BinarySearchToTargetTactic: ShrinkTactic {
    let name = "binarySearchToTarget"
    let applicability = TacticApplicability.numericValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.reduceIntegralValues(
            gen, tree: tree, property: property, sequence: sequence, valueSpans: targetSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

// MARK: Float Stub

private struct ReduceFloatTactic: ShrinkTactic {
    let name = "reduceFloat"
    let applicability = TacticApplicability.floatValues

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        targetSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.reduceFloatValues(
            gen, tree: tree, property: property, sequence: sequence, valueSpans: targetSpans,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

// MARK: Ordering Stub

private struct ReorderSiblingsTactic: SiblingGroupShrinkTactic {
    let name = "reorderSiblings"
    let applicability = TacticApplicability.ordering

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard let (newSequence, output) = try ReducerStrategies.reorderSiblings(
            gen, tree: tree, property: property, sequence: sequence, siblingGroups: siblingGroups,
            rejectCache: &rejectCache, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

// MARK: Cross-Stage Stubs

private struct ReduceInTandemTactic: CrossStageShrinkTactic {
    let name = "reduceInTandem"
    let probeBudget: Int

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        allValueSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        guard siblingGroups.isEmpty == false else { return nil }
        guard let (newSequence, output) = try ReducerStrategies.reduceValuesInTandem(
            gen, tree: tree, property: property, sequence: sequence, siblingGroups: siblingGroups,
            rejectCache: &rejectCache, probeBudget: probeBudget, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}

private struct RedistributeTactic: CrossStageShrinkTactic {
    let name = "redistribute"
    let probeBudget: Int

    func apply<Output>(
        gen: ReflectiveGenerator<Output>,
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        siblingGroups: [SiblingGroup],
        allValueSpans: [ChoiceSpan],
        bindIndex: BindSpanIndex?,
        property: (Output) -> Bool,
        rejectCache: inout ReducerCache,
    ) throws -> ShrinkResult<Output>? {
        let valueCount = sequence.count(where: { $0.value != nil })
        guard valueCount >= 2, valueCount <= 16 else { return nil }
        guard let (newSequence, output) = try ReducerStrategies.redistributeNumericPairs(
            gen, tree: tree, property: property, sequence: sequence,
            rejectCache: &rejectCache, probeBudget: probeBudget, bindIndex: bindIndex
        ) else {
            return nil
        }
        let seed = newSequence.zobristHash
        switch GuidedMaterializer.materialize(gen, prefix: newSequence, seed: seed, fallbackTree: tree) {
        case let .success(_, _, newTree):
            return ShrinkResult(sequence: newSequence, tree: newTree, output: output, evaluations: 1)
        case .filterEncountered, .failed:
            return ShrinkResult(sequence: newSequence, tree: tree, output: output, evaluations: 1)
        }
    }
}
