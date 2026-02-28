//
//  Reducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

public extension Interpreters {
    enum ShrinkConfiguration {
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

    private enum ShrinkPass: String, CaseIterable, Hashable, Equatable, Comparable {
        case naiveSimplifyValuesToSemanticSimplest
        case promoteBranches
        case pivotBranches
        case deleteContainerSpans
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

    @_spi(ExhaustInternal) public static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ShrinkConfiguration,
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
        var oracleCalls = [ShrinkPass: Int]()
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

                let oracle = isInstrumented == false
                    ? property
                    : { v in
                        oracleCalls[pass, default: 0] += 1
                        return property(v)
                    }
                switch pass {
                case .naiveSimplifyValuesToSemanticSimplest:
                    guard didNaivelyMinimise == false else {
                        continue
                    }
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.naiveSimplifyValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        currentOutput = output
                    }
                    // We only run this once
                    didNaivelyMinimise = true
                case .promoteBranches:
                    if let (newTree, newSequence, output) = try ReducerStrategies.promoteBranches(
                        gen,
                        tree: currentTree,
                        property: oracle,
                        sequence: currentSequence,
                        rejectCache: &rejectCache,
                    ) {
                        currentTree = newTree
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .pivotBranches:
                    if let (newTree, newSequence, output) = try ReducerStrategies.pivotBranches(
                        gen,
                        tree: currentTree,
                        property: oracle,
                        sequence: currentSequence,
                        rejectCache: &rejectCache,
                    ) {
                        currentTree = newTree
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteContainerSpans:
                    // Adaptive container span deletion, ie the […] and (…) spans in [(V)(V)]
                    let containerSpans = ChoiceSequence.extractContainerSpans(from: currentSequence)
                    if containerSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: containerSpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteSequenceBoundaries:
                    // Pass 2a: Collapse sequence boundaries, i.e [[V][V][V]] -> [[VVV]]
                    let boundarySpans = ChoiceSequence.extractSequenceBoundarySpans(from: currentSequence)
                    if boundarySpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: boundarySpans, rejectCache: &rejectCache, strictness: .relaxed) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteFreeStandingValues:
                    // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
                    let freeStandingValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: currentSequence)
                    if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: freeStandingValueSpans, rejectCache: &rejectCache, strictness: .relaxed) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteAlignedSiblingWindows:
                    let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.deleteAlignedSiblingWindows(
                           gen,
                           tree: currentTree,
                           property: oracle,
                           sequence: currentSequence,
                           siblingGroups: siblingGroups,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.deleteAlignedSiblingWindows,
                           subsetBeamSearchTuning: alignedDeletionBeamTuning,
                           onBudgetExhausted: budgetLogger,
                       )
                    {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .simplifyValuesToSemanticSimplest:
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.simplifyValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValues:
                    let valueSpans = ChoiceSequence.extractAllValueSpans(from: currentSequence)
                    if valueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.reduceValues(gen, tree: currentTree, property: oracle, sequence: currentSequence, valueSpans: valueSpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .redistributeNumericPairs:
                    let valueCount = currentSequence.count(where: { $0.value != nil })
                    if valueCount >= 2, valueCount <= 16,
                       let (newSequence, output) = try ReducerStrategies.redistributeNumericPairs(
                           gen,
                           tree: currentTree,
                           property: oracle,
                           sequence: currentSequence,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.redistributeNumericPairs,
                           onBudgetExhausted: budgetLogger,
                       )
                    {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .speculativeDeleteAndRepair:
                    let freeValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: currentSequence)
                    let containerSpans = ChoiceSequence.extractContainerSpans(from: currentSequence)
                    let deletableSpans = freeValueSpans + containerSpans
                    if !deletableSpans.isEmpty,
                       let (newSequence, output) = try ReducerStrategies.speculativeDeleteAndRepair(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: deletableSpans, rejectCache: &rejectCache)
                    {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .reduceValuesInTandem:
                    // Reduce individual values in tandem by equal amounts, via binary search
                    let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.reduceValuesInTandem(
                           gen,
                           tree: currentTree,
                           property: oracle,
                           sequence: currentSequence,
                           siblingGroups: siblingGroups,
                           rejectCache: &rejectCache,
                           probeBudget: probeBudgets.reduceValuesInTandem,
                           onBudgetExhausted: budgetLogger,
                       )
                    {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .normaliseSiblingOrder:
                    let siblingGroups = ChoiceSequence.extractSiblingGroups(from: currentSequence)
                    if siblingGroups.isEmpty == false,
                       let (newSequence, output) = try ReducerStrategies.reorderSiblings(gen, tree: currentTree, property: oracle, sequence: currentSequence, siblingGroups: siblingGroups, rejectCache: &rejectCache)
                    {
                        currentSequence = newSequence
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
                                "oracle_calls": "\(oracleCalls[pass, default: 0])",
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
                                "oracle_calls": "\(oracleCalls[pass, default: 0])",
                            ],
                        )
                    }
                    nextPasses.append(pass)
                }
            }
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
//            print("Pass ended. Improved? \(didImprove) \np:\(previousSequence!.shortString) (\(previousSequence!.hashValue))\nc:\(currentSequence.shortString) (\(currentSequence.hashValue))")

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
            oracleCalls
                .map { ($0.key, $0.value) }
                .sorted(by: { $0.0 < $1.0 })
                .forEach { key, value in
                    ExhaustLog.debug(
                        category: .reducer,
                        event: "oracle_call_count",
                        metadata: [
                            "pass": key.rawValue,
                            "calls": "\(value)",
                        ],
                    )
                }
            ExhaustLog.notice(
                category: .reducer,
                event: "oracle_call_total",
                metadata: [
                    "total": "\(oracleCalls.values.reduce(0, +))",
                ],
            )
        }

        return (currentSequence, currentOutput)
    }
}
