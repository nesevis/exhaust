//
//  ScopedSource+Structural.swift
//  Exhaust
//

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(WinSDK)
    import WinSDK
#endif

// MARK: - Structural Preparation

extension ScopedSource {
    /// Prepares the structural families in the order batched cross-sequence removal, emptying, batch removal (one source per sequence), centered windows, symmetric windows, migration, per-element removal, aligned removal, replacement, and permutation, omitting empty ones. The order matters only on priority ties, which go to the earlier source.
    ///
    /// Structural families depend on graph topology, not leaf values, so they survive rebuilds that leave the structure unchanged.
    ///
    /// - Parameter previousGraph: The graph the previous replacement family was prepared from. Self-similar families whose member sizes are unchanged since then are skipped.
    static func prepareStructuralSources(
        from graph: ChoiceGraph,
        previousGraph: ChoiceGraph? = nil,
        tuning _: ScopedReductionTuning
    ) -> [ScopedSource] {
        var sources: [ScopedSource] = []

        let elementScopes = RemovalQuery.elementRemovalScopes(graph: graph)

        var batchedCrossSequence = ScopedSource.batchedCrossSequenceRemoval(ScopedBatchedCrossSequenceRemovalSource(graph: graph))
        if batchedCrossSequence.dispatchPriority != nil {
            sources.append(batchedCrossSequence)
        }

        let emptying = emptyingEncoderScopes(graph: graph, elementScopes: elementScopes)
        if emptying.isEmpty == false {
            sources.append(.emptying(ScopedSortedSource(emptying)))
        }

        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            var batchRemoval = ScopedSource.batchRemoval(ScopedBatchRemovalSource(sequenceNodeID: target.sequenceNodeID, graph: graph))
            if batchRemoval.dispatchPriority != nil {
                sources.append(batchRemoval)
            }
        }

        let centered = centeredWindowEncoderScopes(graph: graph, elementScopes: elementScopes)
        if centered.isEmpty == false {
            sources.append(.centeredWindows(ScopedSortedSource(centered)))
        }

        let symmetric = symmetricWindowEncoderScopes(graph: graph, elementScopes: elementScopes)
        if symmetric.isEmpty == false {
            sources.append(.symmetricWindows(ScopedSortedSource(symmetric)))
        }

        var migration = ScopedSource.migration(ScopedMigrationSource(graph: graph))
        if migration.dispatchPriority != nil {
            sources.append(migration)
        }

        let perElement = perElementRemovalEncoderScopes(graph: graph, elementScopes: elementScopes)
        if perElement.isEmpty == false {
            sources.append(.perElementRemoval(ScopedSortedSource(perElement)))
        }

        let aligned = alignedRemovalEncoderScopes(graph: graph)
        if aligned.isEmpty == false {
            sources.append(.alignedRemoval(ScopedSortedSource(aligned)))
        }

        var replacement = ScopedSource.replacement(ScopedReplacementSource(graph: graph, previousGraph: previousGraph))
        if replacement.dispatchPriority != nil {
            sources.append(replacement)
        }

        sources += preparePermutationSources(from: graph)

        return sources
    }

    /// The permutation family alone, which depends on sibling shapes, so a leaf-kind change rebuilds it while other structural families survive.
    static func preparePermutationSources(from graph: ChoiceGraph) -> [ScopedSource] {
        let permutation = permutationEncoderScopes(graph: graph)
        guard permutation.isEmpty == false else {
            return []
        }
        return [.permutation(ScopedSortedSource(permutation))]
    }

    /// The numeric reorder family over the current graph: one scope holding every reorderable sibling group, or nil when there is none. Reordering is for presentation, so the runner drains this family only in the final pass.
    static func prepareReorderSource(from graph: ChoiceGraph) -> ScopedSource? {
        guard let reorderScope = ReorderingQuery.build(graph: graph) else {
            return nil
        }
        return .numericReorder(ScopedSortedSource(
            [PricedEncoderScope(
                encoderScope: .reorder(reorderScope),
                priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
            )]
        ))
    }

    // MARK: - Removal Families

    /// One scope per sequence whose minimum length is zero, removing all its elements: the largest structural reduction per sequence. Largest yield first.
    private static func emptyingEncoderScopes(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []
        for scope in elementScopes {
            // Only single-target (per-parent) scopes are emptied.
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            guard case let .sequence(metadata) = graph.nodes[target.sequenceNodeID].kind else {
                continue
            }
            let minLength = Int(metadata.lengthConstraint?.lowerBound ?? 0)
            guard metadata.elementCount > minLength else {
                continue
            }
            guard minLength == 0 else {
                continue
            }
            let totalYield = target.elementNodeIDs.reduce(0) { total, nodeID in
                total + (graph.nodes[nodeID].positionRange?.count ?? 0)
            }

            let emptyingScope = ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: target.sequenceNodeID,
                    elementNodeIDs: target.elementNodeIDs
                )],
                maxBatch: target.elementNodeIDs.count,
                maxElementYield: totalYield
            )

            results.append(PricedEncoderScope(
                encoderScope: .removal(.elements(emptyingScope)),
                priority: DispatchPriority(
                    structuralBenefit: totalYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Seeds center-out deletion with the largest centered window allowed by each sequence's minimum length.
    ///
    /// Keeping the window's parity equal to the sequence's makes the first probe remove its middle element or middle pair. Its dispatch priority reflects only that first probe; later growth is driven by acceptance feedback.
    private static func centeredWindowEncoderScopes(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            let elements = target.elementNodeIDs
            var capacity = min(scope.maxBatch, elements.count)
            if capacity % 2 != elements.count % 2 {
                capacity -= 1
            }
            guard capacity > 0 else {
                continue
            }
            let start = (elements.count - capacity) / 2
            let window = WindowRemovalScope(
                sequenceNodeID: target.sequenceNodeID,
                elementNodeIDs: Array(elements[start ..< start + capacity]),
                growth: .outward
            )
            guard let initialNodeIDs = window.removalNodeIDs(step: 1) else {
                continue
            }
            let initialYield = initialNodeIDs.reduce(0) { total, nodeID in
                total + (graph.nodes[nodeID].positionRange?.count ?? 0)
            }
            results.append(PricedEncoderScope(
                encoderScope: .removal(.window(window)),
                priority: DispatchPriority(
                    structuralBenefit: initialYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// Seeds equal prefix and suffix deletions within each sequence's minimum-length budget.
    ///
    /// The first probe removes both edge elements together. Increasing the search step grows both arms inward; the retained middle is omitted from the scope so it cannot be deleted or counted twice. Priority reflects only the first pair's yield.
    private static func symmetricWindowEncoderScopes(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [PricedEncoderScope] {
        var results: [PricedEncoderScope] = []
        for scope in elementScopes {
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            let elements = target.elementNodeIDs
            let pairCapacity = min(scope.maxBatch / 2, elements.count / 2)
            guard pairCapacity > 0 else {
                continue
            }
            let window = WindowRemovalScope(
                sequenceNodeID: target.sequenceNodeID,
                elementNodeIDs: Array(elements.prefix(pairCapacity)) + Array(elements.suffix(pairCapacity)),
                growth: .symmetric
            )
            let initialYield = (graph.nodes[elements[0]].positionRange?.count ?? 0)
                + (graph.nodes[elements[elements.count - 1]].positionRange?.count ?? 0)
            results.append(PricedEncoderScope(
                encoderScope: .removal(.window(window)),
                priority: DispatchPriority(
                    structuralBenefit: initialYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            ))
        }
        results.sort { $0.priority > $1.priority }
        return results
    }

    /// One scope per deletable element, removing it alone. Elements already at their reduction target come first, because removing an already-minimal element is more likely to keep the property failing; the rest follow in position order.
    private static func perElementRemovalEncoderScopes(graph: ChoiceGraph, elementScopes: [ElementRemovalScope]) -> [PricedEncoderScope] {
        var entries: [(sequenceNodeID: Int, nodeID: Int, positionRange: ClosedRange<Int>, isZero: Bool)] = []
        for scope in elementScopes {
            // Only single-target scopes are split into elements.
            guard scope.targets.count == 1, let target = scope.targets.first else {
                continue
            }
            for elementNodeID in target.elementNodeIDs {
                guard let range = graph.nodes[elementNodeID].positionRange else {
                    continue
                }
                let isZero = switch graph.nodes[elementNodeID].kind {
                    case let .chooseBits(metadata):
                        metadata.value.bitPattern64 == metadata.value.reductionTarget(in: metadata.validRange)
                    default:
                        false
                }
                entries.append((
                    sequenceNodeID: target.sequenceNodeID,
                    nodeID: elementNodeID,
                    positionRange: range,
                    isZero: isZero
                ))
            }
        }
        // At-target elements first, then by position.
        entries.sort { entryA, entryB in
            if entryA.isZero != entryB.isZero {
                return entryA.isZero
            }
            return entryA.positionRange.lowerBound < entryB.positionRange.lowerBound
        }

        return entries.map { element in
            let scope = ElementRemovalScope(
                targets: [SequenceRemovalTarget(
                    sequenceNodeID: element.sequenceNodeID,
                    elementNodeIDs: [element.nodeID]
                )],
                maxBatch: 1,
                maxElementYield: element.positionRange.count
            )
            return PricedEncoderScope(
                encoderScope: .removal(.elements(scope)),
                priority: DispatchPriority(
                    structuralBenefit: element.positionRange.count,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: 1
                )
            )
        }
    }

    /// One covering-array scope per zip with two or more deletable sibling sequences, largest single-element yield first. The cost is the rows one dispatch can pull: the generator's remaining rows, up to ``CoveringAlignedRemovalScope/rowBudget``.
    private static func alignedRemovalEncoderScopes(graph: ChoiceGraph) -> [PricedEncoderScope] {
        let scopes = RemovalQuery.coveringAlignedRemovalScopes(graph: graph)
            .sorted { $0.maxElementYield > $1.maxElementYield }

        return scopes.map { scope in
            PricedEncoderScope(
                encoderScope: .removal(.coveringAligned(scope)),
                priority: DispatchPriority(
                    structuralBenefit: scope.maxElementYield,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: min(CoveringAlignedRemovalScope.rowBudget, scope.generator.totalRemaining)
                )
            )
        }
    }

    // MARK: - Permutation Family

    /// One scope per same-shaped sibling group, earliest group first, since earlier positions affect shortlex order most. The cost is the swap's probe count: one for a pair, otherwise one plus the extension's logarithmic bound.
    private static func permutationEncoderScopes(graph: ChoiceGraph) -> [PricedEncoderScope] {
        var entries: [(parentNodeID: Int, group: [Int], position: Int)] = []
        for scope in PermutationQuery.build(graph: graph) {
            let parentNodeID = scope.parentNodeID
            for group in scope.swappableGroups {
                guard group.count >= 2 else {
                    continue
                }
                let position = graph.nodes[group[0]].positionRange?.lowerBound ?? 0
                entries.append((parentNodeID: parentNodeID, group: group, position: position))
            }
        }
        entries.sort { $0.position < $1.position }

        return entries.map { entry in
            let estimatedCost = entry.group.count <= 2 ? 1 : (1 + Int(log2(Double(entry.group.count))))
            return PricedEncoderScope(
                encoderScope: .swap(PermutationScope(
                    parentNodeID: entry.parentNodeID,
                    swappableGroups: [entry.group]
                )),
                priority: DispatchPriority(
                    structuralBenefit: 0,
                    valueBenefit: 0,
                    reductionMagnitude: 0,
                    estimatedCost: estimatedCost
                )
            )
        }
    }
}
