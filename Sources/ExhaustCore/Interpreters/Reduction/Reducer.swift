//
//  Reducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

public extension Interpreters {
    /// Configuration presets for the reducer's test case reduction strategies.
    enum TCRConfiguration {
        /// Per-strategy probe budgets controlling how many candidates each strategy evaluates.
        struct ProbeBudgets {
            let deleteAlignedSiblingWindows: Int
            let redistributeNumericPairs: Int
            let reduceValuesInTandem: Int

            static let fast = Self(
                deleteAlignedSiblingWindows: 400,
                redistributeNumericPairs: 600,
                reduceValuesInTandem: 400,
            )

            static let slow = Self(
                deleteAlignedSiblingWindows: 2000,
                redistributeNumericPairs: 3000,
                reduceValuesInTandem: 2000,
            )
        }

        /// Tuning parameters for the beam search used by aligned sibling deletion.
        struct AlignedDeletionBeamSearchTuning {
            let minBeamWidth: Int
            let beamWidthScale: Int
            let maxBeamWidth: Int
            let minEvaluationsPerLayer: Int
            let evaluationsPerLayerScale: Int

            static let fast = Self(
                minBeamWidth: 12,
                beamWidthScale: 2,
                maxBeamWidth: 48,
                minEvaluationsPerLayer: 6,
                evaluationsPerLayerScale: 1,
            )

            static let slow = Self(
                minBeamWidth: 18,
                beamWidthScale: 3,
                maxBeamWidth: 96,
                minEvaluationsPerLayer: 10,
                evaluationsPerLayerScale: 2,
            )

            func beamWidth(for slotCount: Int) -> Int {
                min(max(minBeamWidth, slotCount * beamWidthScale), maxBeamWidth)
            }

            func evaluationsPerLayer(for slotCount: Int, beamWidth: Int) -> Int {
                min(max(minEvaluationsPerLayer, slotCount * evaluationsPerLayerScale), beamWidth)
            }
        }

        case fast
        case slow

        var maxStalls: Int {
            switch self {
            case .fast:
                3
            case .slow:
                8
            }
        }

        var recentCycleWindow: Int {
            switch self {
            case .fast:
                6
            case .slow:
                12
            }
        }

        var probeBudgets: ProbeBudgets {
            switch self {
            case .fast:
                .fast
            case .slow:
                .slow
            }
        }

        var alignedDeletionBeamSearchTuning: AlignedDeletionBeamSearchTuning {
            switch self {
            case .fast:
                .fast
            case .slow:
                .slow
            }
        }
    }

    // MARK: - Academic Provenance

    //
    // Internal test-case reduction — shrinking by shortlex-optimizing choice sequences rather than output values — originates with MacIver & Donaldson (ECOOP 2020, "Reduction via Generation"). Goldstein §4.6 formalizes three specific passes in the context of reflective generators:
    //
    //   Goldstein §4.6   Exhaust equivalent
    //   ──────────────   ──────────────────────────────
    //   subTrees       → promoteBranches
    //   zeroDraws      → naiveSimplifyValuesToSemanticSimplest + simplifyValuesToSemanticSimplest
    //   swapBits       → reduceIntegralValues + reduceFloatValues
    //
    // Exhaust extends the reducer with ten additional passes: pivotBranches, deleteContainerSpans, deleteSequenceBoundaries, deleteFreeStandingValues, deleteAlignedSiblingWindows, reduceValuesInTandem, redistributeNumericPairs, speculativeDeleteAndRepair, normaliseSiblingOrder.
    //
    // Shortlex ordering (MacIver & Donaldson §2.2) is the reduction order: shorter choice sequences are always preferred, with lexicographic comparison as tiebreaker. The adaptive `findInteger` and `binarySearchWithGuess` probes used throughout are from MacIver's Hypothesis (see AdaptiveProbe.swift).

    private enum ShrinkPass: String, CaseIterable, Hashable, Equatable, Comparable {
        case naiveSimplifyValuesToSemanticSimplest
        case promoteBranches
        case pivotBranches
        case deleteContainerSpans
        case deleteSequenceElements
        case deleteSequenceBoundaries
        case deleteFreeStandingValues
        case deleteAlignedSiblingWindows
        case simplifyValuesToSemanticSimplest
        case reduceValuesInTandem
        case reduceIntegralValues
        case reduceFloatValues
        case redistributeNumericPairs
        case speculativeDeleteAndRepair
        case normaliseSiblingOrder

        static func < (lhs: Interpreters.ShrinkPass, rhs: Interpreters.ShrinkPass) -> Bool {
            (allCases.firstIndex(of: lhs) ?? 0) < (allCases.firstIndex(of: rhs) ?? 0)
        }
    }

    private struct SpanCache {
        private var allValueSpans: [ChoiceSpan]?
        private var siblingGroups: [SiblingGroup]?
        private var containerSpans: [ChoiceSpan]?
        private var sequenceElementSpans: [ChoiceSpan]?
        private var freeStandingValueSpans: [ChoiceSpan]?
        private var sequenceBoundarySpans: [ChoiceSpan]?
        private var floatValueSpans: [ChoiceSpan]?

        mutating func invalidate() {
            allValueSpans = nil
            siblingGroups = nil
            containerSpans = nil
            sequenceElementSpans = nil
            freeStandingValueSpans = nil
            sequenceBoundarySpans = nil
            floatValueSpans = nil
        }

        mutating func getAllValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
            if let cached = allValueSpans { return cached }
            let spans = ChoiceSequence.extractAllValueSpans(from: sequence)
            allValueSpans = spans
            return spans
        }

        mutating func getSiblingGroups(from sequence: ChoiceSequence) -> [SiblingGroup] {
            if let cached = siblingGroups { return cached }
            let groups = ChoiceSequence.extractSiblingGroups(from: sequence)
            siblingGroups = groups
            return groups
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

        mutating func getFreeStandingValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
            if let cached = freeStandingValueSpans { return cached }
            let spans = ChoiceSequence.extractFreeStandingValueSpans(from: sequence)
            freeStandingValueSpans = spans
            return spans
        }

        mutating func getSequenceBoundarySpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
            if let cached = sequenceBoundarySpans { return cached }
            let spans = ChoiceSequence.extractSequenceBoundarySpans(from: sequence)
            sequenceBoundarySpans = spans
            return spans
        }

        mutating func getFloatValueSpans(from sequence: ChoiceSequence) -> [ChoiceSpan] {
            if let cached = floatValueSpans { return cached }
            let all = getAllValueSpans(from: sequence)
            let spans = all.filter { span in
                guard let v = sequence[span.range.lowerBound].value else { return false }
                return v.choice.tag == .double || v.choice.tag == .float
            }
            floatValueSpans = spans
            return spans
        }
    }

    static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: TCRConfiguration,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        // Mutable variables
        let isInstrumented = ExhaustLog.isEnabled(.debug, for: .reducer)
        var currentSequence = ChoiceSequence.flatten(tree)
        // I don't think we need to reflect to regenerate this?
        // There is then a hard dependency on having to have reflectable generators, which is a pain
        var currentTree = tree
        guard var currentOutput = try materialize(gen, with: tree, using: currentSequence) else {
            return nil
        }
        var numberOfImprovements = 0
        var propertyInvocations = [ShrinkPass: Int]()
        var stallBudget = config.maxStalls
        let probeBudgets = config.probeBudgets
        let alignedDeletionBeamTuning = config.alignedDeletionBeamSearchTuning
        let budgetLogger: ((String) -> Void)? = isInstrumented ? { message in
            ExhaustLog.notice(
                category: .reducer,
                event: "probe_budget_exhausted",
                message,
            )
        } : nil
        let hasBind = tree.containsBind
        var bindSpanIndex: BindSpanIndex? = hasBind
            ? BindSpanIndex(from: currentSequence)
            : nil
        let maxBindDepth = bindSpanIndex?.maxBindDepth ?? 0
        var currentBindDepth = 0
        var depthCycleImproved = false
        var depthCyclesRemaining = 2
        var didNaivelyMinimise = false
        var loops = 0
        var passes = ShrinkPass.allCases
        var rejectCache = ReducerCache()
        var spanCache = SpanCache()
        // Tracks recent loop-end states to detect local oscillation.
        var recentSequences = [currentSequence]
        while stallBudget > 0 {
            loops += 1
            var didImprove = false
            var nextPasses = [ShrinkPass]()
            if isInstrumented {
                ExhaustLog.debug(
                    category: .reducer,
                    event: "loop_start",
                    metadata: [
                        "loop": "\(loops)",
                        "stall_budget": "\(stallBudget)",
                        "sequence": currentSequence.shortString,
                        "current_bind_depth": currentBindDepth.description
                    ],
                )
            }
            for pass in passes {
                let property = isInstrumented == false
                ? property
                : { v in
                    propertyInvocations[pass, default: 0] += 1
                    return property(v)
                }
                // The order of shrink passes to take next turn
                var passImproved = false

                switch pass {
                case .naiveSimplifyValuesToSemanticSimplest:
                    guard didNaivelyMinimise == false else {
                        continue
                    }
                    var valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if let bi = bindSpanIndex {
                        valueSpans = valueSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == currentBindDepth }
                    }
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.naiveSimplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                    }
                    // We only run this once
                    didNaivelyMinimise = true
                case .promoteBranches:
                    if let (newTree, newSequence, output) = try ReducerStrategies.promoteBranches(
                        gen,
                        tree: currentTree,
                        property: property,
                        sequence: currentSequence,
                        rejectCache: &rejectCache,
                        bindIndex: bindSpanIndex,
                    ) {
                        currentTree = newTree
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .pivotBranches:
                    if let (newTree, newSequence, output) = try ReducerStrategies.pivotBranches(
                        gen,
                        tree: currentTree,
                        property: property,
                        sequence: currentSequence,
                        rejectCache: &rejectCache,
                        bindIndex: bindSpanIndex,
                    ) {
                        currentTree = newTree
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteContainerSpans:
                    // Adaptive container span deletion, ie the […] and (…) spans in [(V)(V)]
                    let containerSpans = spanCache.getContainerSpans(from: currentSequence)
                    if containerSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: containerSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteSequenceElements:
                    // Delete group spans that are direct children of a sequence (array elements).
                    // Uses .relaxed strictness because removing elements shifts entries out of
                    // alignment with the tree's per-position structure.
                    let seqElemSpans = spanCache.getSequenceElementSpans(from: currentSequence)
                    if seqElemSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: seqElemSpans, rejectCache: &rejectCache, strictness: .relaxed, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteSequenceBoundaries:
                    // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
                    let boundarySpans = spanCache.getSequenceBoundarySpans(from: currentSequence)
                    if boundarySpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: boundarySpans, rejectCache: &rejectCache, strictness: .relaxed, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                        // After merging sequences, inner sequence lengths may exceed the tree's
                        // recorded ranges. Relax non-explicit length ranges so subsequent passes
                        // can still materialize the modified sequence.
                        currentTree = currentTree.relaxingNonExplicitSequenceLengthRanges()
                    }
                case .deleteFreeStandingValues:
                    // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
                    let freeStandingValueSpans = spanCache.getFreeStandingValueSpans(from: currentSequence)
                    if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: freeStandingValueSpans, rejectCache: &rejectCache, strictness: .relaxed, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteAlignedSiblingWindows:
                    let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.deleteAlignedSiblingWindows(
                           gen,
                           tree: currentTree,
                           property: property,
                           sequence: currentSequence,
                           siblingGroups: siblingGroups,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.deleteAlignedSiblingWindows,
                           subsetBeamSearchTuning: alignedDeletionBeamTuning,
                           onBudgetExhausted: budgetLogger,
                           bindIndex: bindSpanIndex,
                       )
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .simplifyValuesToSemanticSimplest:
                    var valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if let bi = bindSpanIndex {
                        valueSpans = valueSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == currentBindDepth }
                    }
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.simplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceIntegralValues:
                    var valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if let bi = bindSpanIndex {
                        valueSpans = valueSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == currentBindDepth }
                    }
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.reduceIntegralValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceFloatValues:
                    var floatSpans = spanCache.getFloatValueSpans(from: currentSequence)
                    if let bi = bindSpanIndex {
                        floatSpans = floatSpans.filter { bi.bindDepth(at: $0.range.lowerBound) == currentBindDepth }
                    }
                    if floatSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.reduceFloatValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: floatSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .redistributeNumericPairs:
                    let valueCount = currentSequence.count(where: { $0.value != nil })
                    if valueCount >= 2, valueCount <= 16,
                       let (newSequence, output) = try ReducerStrategies.redistributeNumericPairs(
                           gen,
                           tree: currentTree,
                           property: property,
                           sequence: currentSequence,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.redistributeNumericPairs,
                           onBudgetExhausted: budgetLogger,
                           bindIndex: bindSpanIndex,
                       )
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .speculativeDeleteAndRepair:
                    let freeValueSpans = spanCache.getFreeStandingValueSpans(from: currentSequence)
                    let containerSpans = spanCache.getContainerSpans(from: currentSequence)
                    let deletableSpans = freeValueSpans + containerSpans
                    if !deletableSpans.isEmpty,
                       let (newSequence, output) = try ReducerStrategies.speculativeDeleteAndRepair(gen, tree: currentTree, property: property, sequence: currentSequence, spans: deletableSpans, rejectCache: &rejectCache, bindIndex: bindSpanIndex)
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValuesInTandem:
                    // Reduce individual values in tandem by equal amounts, via binary search
                    let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.reduceValuesInTandem(
                           gen,
                           tree: currentTree,
                           property: property,
                           sequence: currentSequence,
                           siblingGroups: siblingGroups,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.reduceValuesInTandem,
                           onBudgetExhausted: budgetLogger,
                           bindIndex: bindSpanIndex,
                       )
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .normaliseSiblingOrder:
                    let siblingGroups = spanCache.getSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.reorderSiblings(gen, tree: currentTree, property: property, sequence: currentSequence, siblingGroups: siblingGroups, rejectCache: &rejectCache, bindIndex: bindSpanIndex)
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                }
                if passImproved {
                    if hasBind { bindSpanIndex = BindSpanIndex(from: currentSequence) }
                    if isInstrumented {
                        ExhaustLog.debug(
                            category: .reducer,
                            event: "pass_succeeded",
                            metadata: [
                                "pass": pass.rawValue,
                                "property_invocations": "\(propertyInvocations[pass, default: 0])",
                                "output": "\(currentOutput)",
                            ],
                        )
                    }
                    didImprove = true
                    depthCycleImproved = true
                    nextPasses.insert(pass, at: 0)
                } else {
                    if isInstrumented {
                        ExhaustLog.debug(
                            category: .reducer,
                            event: "pass_failed",
                            metadata: [
                                "pass": pass.rawValue,
                                "property_invocations": "\(propertyInvocations[pass, default: 0])",
                            ],
                        )
                    }
                    nextPasses.append(pass)
                }
            } // End pass for loop

            passes = nextPasses
            if didImprove {
                let recentWindow = recentSequences.suffix(config.recentCycleWindow)
                if recentWindow.contains(currentSequence) {
                    if isInstrumented {
                        ExhaustLog.notice(
                            category: .reducer,
                            event: "cycle_detected",
                            metadata: [
                                "window": "\(config.recentCycleWindow)",
                            ],
                        )
                    }
                    break
                }

                recentSequences.append(currentSequence)
                let maxHistory = max(config.recentCycleWindow * 2, config.recentCycleWindow + 1)
                if recentSequences.count > maxHistory {
                    recentSequences.removeFirst(recentSequences.count - maxHistory)
                }
                numberOfImprovements += 1
                stallBudget = config.maxStalls
                continue
            }

            // No pass improved at current depth — try advancing to next bind depth.
            if maxBindDepth > 0, depthCyclesRemaining > 0 {
                let nextDepth = (currentBindDepth + 1) % (maxBindDepth + 1)

                // Full cycle with no improvement → fall through to stall decrement.
                if nextDepth == 0, depthCycleImproved == false {
                    // fall through
                } else {
                    if nextDepth == 0 { depthCyclesRemaining -= 1 }
                    // Rebuild consistent (sequence, tree) and advance depth.
                    let beforeSeq = currentSequence
                    let seed = currentSequence.zobristHash
                    if case let .success(value, seq, newTree) =
                        GuidedMaterializer.materialize(gen, prefix: currentSequence, seed: seed),
                       property(value) == false
                    {
                        // GuidedMaterializer regenerates bound content from PRNG, discarding
                        // any progress made shrinking at deeper bind depths. Restore the
                        // shortlex-smaller of the two choices at each bound position so that
                        // shrinking work from previous depth passes is not lost.
                        var mergedSeq = seq
                        var didMerge = false
                        if let bi = bindSpanIndex {
                            let newBi = BindSpanIndex(from: seq)
                            for (oldRegion, newRegion) in zip(bi.regions, newBi.regions) {
                                for (oldIdx, newIdx) in zip(oldRegion.boundRange, newRegion.boundRange) {
                                    if beforeSeq[oldIdx].shortLexCompare(seq[newIdx]) == .lt {
                                        mergedSeq[newIdx] = beforeSeq[oldIdx]
                                        didMerge = true
                                    }
                                }
                            }
                        }
                        if didMerge, mergedSeq.shortLexPrecedes(seq),
                           let mergedResult = try? materialize(gen, with: newTree, using: mergedSeq),
                           property(mergedResult) == false
                        {
                            currentSequence = mergedSeq
                            currentOutput = mergedResult
                        } else {
                            currentSequence = seq
                            currentOutput = value
                        }
                        currentTree = newTree
                        bindSpanIndex = BindSpanIndex(from: currentSequence)
                        spanCache.invalidate()
                        rejectCache = ReducerCache()
                        currentBindDepth = nextDepth
                        if nextDepth == 0 { depthCycleImproved = false }
                        didNaivelyMinimise = false
                        continue
                    }
                }
            }
            
            stallBudget -= 1
        }

        if isInstrumented {
            ExhaustLog.notice(
                category: .reducer,
                event: "stalled",
                metadata: [
                    "loops": "\(loops)",
                    "improvements": "\(numberOfImprovements)",
                ],
            )
            propertyInvocations
                .map { ($0.key, $0.value) }
                .sorted(by: { $0.0 < $1.0 })
                .forEach { key, value in
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "property_invocation_count",
                        metadata: [
                            "pass": key.rawValue,
                            "calls": "\(value)",
                        ],
                    )
                }
            ExhaustLog.notice(
                category: .reducer,
                event: "property_invocation_count_total",
                metadata: [
                    "total": "\(propertyInvocations.values.reduce(0, +))",
                ],
            )
        }

        return (currentSequence, currentOutput)
    }
}
