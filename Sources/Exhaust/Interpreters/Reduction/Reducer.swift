//
//  Reducer.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation

public extension Interpreters {
    enum ShrinkConfiguration {
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
    }

    private enum ShrinkPass: String, CaseIterable, Hashable, Equatable, Comparable {
        case naiveSimplifyValuesToSemanticSimplest
        case deleteContainerSpans
        case deleteSequenceBoundaries
        case deleteFreeStandingValues
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

    static func reduce<Output>(
        gen: ReflectiveGenerator<Output>,
        tree: ChoiceTree,
        config: ShrinkConfiguration,
        property: (Output) -> Bool,
    ) throws -> (ChoiceSequence, Output)? {
        // Mutable variables
        let isInstrumented = false
        var currentSequence = ChoiceSequence.flatten(tree)
        // I don't think we need to reflect to regenerate this?
        // There is then a hard dependency on having to have reflectable generators, which is a pain
        let currentTree = tree
        guard var currentOutput = try materialize(gen, with: tree, using: currentSequence) else {
            return nil
        }
        var numberOfImprovements = 0
        var oracleCalls = [ShrinkPass: Int]()
        var stallBudget = config.maxStalls
        var didNaivelyMinimise = false
        var loops = 0
        var passes = ShrinkPass.allCases
        var rejectCache = ReducerCache()
        var seen = Set<ChoiceSequence>()
        while stallBudget > 0 {
            loops += 1
            var didImprove = false
            var nextPasses = [ShrinkPass]()
            if isInstrumented {
                print("Reducer, loop \(loops)")
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
                    if boundarySpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: boundarySpans, rejectCache: &rejectCache) {
                        currentSequence = newSequence
                        currentOutput = output
                        passImproved = true
                    }
                case .deleteFreeStandingValues:
                    // Pass 2b: Sequence element deletion, i.e the individual Vs in [VVVVV]
                    let freeStandingValueSpans = ChoiceSequence.extractFreeStandingValueSpans(from: currentSequence)
                    if freeStandingValueSpans.isEmpty == false, let (newSequence, output) = try ReducerStrategies.adaptiveDeleteSpans(gen, tree: currentTree, property: oracle, sequence: currentSequence, spans: freeStandingValueSpans, rejectCache: &rejectCache) {
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
                       let (newSequence, output) = try ReducerStrategies.redistributeNumericPairs(gen, tree: currentTree, property: oracle, sequence: currentSequence, rejectCache: &rejectCache)
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
                    if siblingGroups.isEmpty == false, let (newSequence, output) = try ReducerStrategies.reduceValuesInTandem(gen, tree: currentTree, property: oracle, sequence: currentSequence, siblingGroups: siblingGroups, rejectCache: &rejectCache) {
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
                        print("> \(pass) succeeded \(oracleCalls[pass, default: 0]) \(currentOutput)")
                    }
                    didImprove = true
                    nextPasses.insert(pass, at: 0)
                } else {
                    if isInstrumented {
                        print("x \(pass) failed \(oracleCalls[pass, default: 0])")
                    }
                    nextPasses.append(pass)
                }
            }
            passes = nextPasses
            if didImprove, seen.contains(currentSequence) == false {
                seen.insert(currentSequence)
//                print("! improved! \(currentOutput)")
                numberOfImprovements += 1
                stallBudget = config.maxStalls
                continue
            }
//            print("Pass ended. Improved? \(didImprove) \np:\(previousSequence!.shortString) (\(previousSequence!.hashValue))\nc:\(currentSequence.shortString) (\(currentSequence.hashValue))")

            // No pass improved the sequence — further iterations are deterministic, so stop.
            stallBudget -= 1
        }

        if isInstrumented {
            print("Shrinker stalled after \(loops) loops.")
            oracleCalls
                .map { ($0.key, $0.value) }
                .sorted(by: { $0.0 < $1.0 })
                .forEach { key, value in
                    print("— \(value):\t\(key)")
                }
            print("\(oracleCalls.values.reduce(0, +)) oracle calls, total")
        }

        return (currentSequence, currentOutput)
    }
}
