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
    //   swapBits       → reduceValues
    //
    // Exhaust extends the reducer with nine additional passes: pivotBranches, deleteContainerSpans, deleteSequenceBoundaries, deleteFreeStandingValues, deleteAlignedSiblingWindows, reduceValuesInTandem, redistributeNumericPairs, speculativeDeleteAndRepair, normaliseSiblingOrder.
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
        case reduceValues
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

        mutating func invalidate() {
            allValueSpans = nil
            siblingGroups = nil
            containerSpans = nil
            sequenceElementSpans = nil
            freeStandingValueSpans = nil
            sequenceBoundarySpans = nil
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
                    ],
                )
            }
            for pass in passes {
                // The order of shrink passes to take next turn
                var passImproved = false

                let property = isInstrumented == false
                    ? property
                    : { v in
                        propertyInvocations[pass, default: 0] += 1
                        return property(v)
                    }
                switch pass {
                case .naiveSimplifyValuesToSemanticSimplest:
                    guard didNaivelyMinimise == false else {
                        continue
                    }
                    let valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.naiveSimplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
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
                    if containerSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: containerSpans, rejectCache: &rejectCache) {
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
                    if seqElemSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: seqElemSpans, rejectCache: &rejectCache, strictness: .relaxed) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteSequenceBoundaries:
                    // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
                    let boundarySpans = spanCache.getSequenceBoundarySpans(from: currentSequence)
                    if boundarySpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: boundarySpans, rejectCache: &rejectCache, strictness: .relaxed) {
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
                    if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: property, sequence: currentSequence, spans: freeStandingValueSpans, rejectCache: &rejectCache, strictness: .relaxed) {
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
                       )
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .simplifyValuesToSemanticSimplest:
                    let valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.simplifyValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValues:
                    let valueSpans = spanCache.getAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.reduceValues(gen, tree: currentTree, property: property, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
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
                       let (newSequence, output) = try ReducerStrategies.speculativeDeleteAndRepair(gen, tree: currentTree, property: property, sequence: currentSequence, spans: deletableSpans, rejectCache: &rejectCache)
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
                       let (newSequence, output) = try ReducerStrategies.reorderSiblings(gen, tree: currentTree, property: property, sequence: currentSequence, siblingGroups: siblingGroups, rejectCache: &rejectCache)
                    {
                        currentSequence = newSequence
                        spanCache.invalidate()
                        currentOutput = output
                        passImproved = true
                    }
                }
                if passImproved {
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

            // No pass improved the sequence — further iterations are deterministic, so stop.
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
