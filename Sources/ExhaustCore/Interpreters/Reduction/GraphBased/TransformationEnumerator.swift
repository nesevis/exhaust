//
//  TransformationEnumerator.swift
//  Exhaust
//

// MARK: - Transformation Enumerator

/// Walks the ``ChoiceGraph``, calls scope queries, computes grades, and produces a sorted queue of ``GraphTransformation`` values.
///
/// The enumerator is the bridge between the graph's structural knowledge and the scheduler's priority queue. It calls all seven scope queries, wraps each scope in a ``GraphTransformation`` with its computed grade (yield, precondition, postcondition), and returns the full sorted array.
///
/// - Complexity: O(*N* + *L* + *E*) where *N* is the node count, *L* is the leaf count, and *E* is the edge count. For a 100-node graph, this is microseconds — three orders of magnitude cheaper than a single property invocation.
enum TransformationEnumerator {

    /// Enumerates all transformation scopes from the graph and returns them sorted by yield (highest priority first).
    ///
    /// - Parameter graph: The current choice graph.
    /// - Returns: Sorted array of graph transformations, ready for the scheduler's priority queue.
    static func enumerate(from graph: ChoiceGraph) -> [GraphTransformation] {
        let innerChildToBind = buildInnerChildToBind(from: graph)
        var transformations: [GraphTransformation] = []

        transformations.append(contentsOf: removalTransformations(from: graph))
        transformations.append(contentsOf: replacementTransformations(from: graph))
        transformations.append(contentsOf: minimizationTransformations(
            from: graph,
            innerChildToBind: innerChildToBind
        ))
        transformations.append(contentsOf: exchangeTransformations(
            from: graph,
            innerChildToBind: innerChildToBind
        ))
        transformations.append(contentsOf: permutationTransformations(from: graph))

        transformations.sort { $0.yield < $1.yield }
        return transformations
    }

    // MARK: - Removal

    private static func removalTransformations(
        from graph: ChoiceGraph
    ) -> [GraphTransformation] {
        var result: [GraphTransformation] = []

        for scope in graph.alignedRemovalScopes() {
            let estimatedProbes = 2 * ceilLog2(scope.maxAlignedWindow)
            result.append(GraphTransformation(
                operation: .remove(.aligned(scope)),
                yield: TransformationYield(
                    structural: scope.maxYield,
                    value: 0,
                    slack: .exact,
                    estimatedProbes: max(1, estimatedProbes)
                ),
                precondition: .all(scope.siblings.map {
                    .sequenceLengthAboveMinimum(sequenceNodeID: $0.sequenceNodeID)
                }),
                postcondition: TransformationPostcondition(
                    isStructural: true,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ))
        }

        for scope in graph.perParentRemovalScopes() {
            let estimatedProbes = 2 * ceilLog2(scope.maxBatch)
            result.append(GraphTransformation(
                operation: .remove(.perParent(scope)),
                yield: TransformationYield(
                    structural: scope.elementNodeIDs.reduce(0) { total, nodeID in
                        total + (graph.nodes[nodeID].positionRange?.count ?? 0)
                    },
                    value: 0,
                    slack: .exact,
                    estimatedProbes: max(1, estimatedProbes)
                ),
                precondition: .sequenceLengthAboveMinimum(
                    sequenceNodeID: scope.sequenceNodeID
                ),
                postcondition: TransformationPostcondition(
                    isStructural: true,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ))
        }

        for scope in graph.subtreeRemovalScopes() {
            result.append(GraphTransformation(
                operation: .remove(.subtree(scope)),
                yield: TransformationYield(
                    structural: scope.yield,
                    value: 0,
                    slack: .exact,
                    estimatedProbes: 1
                ),
                precondition: .nodeActive(scope.nodeID),
                postcondition: TransformationPostcondition(
                    isStructural: true,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            ))
        }

        return result
    }

    // MARK: - Replacement

    private static func replacementTransformations(
        from graph: ChoiceGraph
    ) -> [GraphTransformation] {
        var result: [GraphTransformation] = []

        for scope in graph.replacementScopes() {
            switch scope {
            case let .selfSimilar(selfSimilarScope):
                result.append(GraphTransformation(
                    operation: .replace(scope),
                    yield: TransformationYield(
                        structural: max(0, selfSimilarScope.sizeDelta),
                        value: 0,
                        slack: .exact,
                        estimatedProbes: 1
                    ),
                    precondition: .all([
                        .nodeActive(selfSimilarScope.targetNodeID),
                        .nodeActive(selfSimilarScope.donorNodeID),
                    ]),
                    postcondition: TransformationPostcondition(
                        isStructural: selfSimilarScope.sizeDelta != 0,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))

            case let .branchPivot(pivotScope):
                let activeSize = graph.nodes[pivotScope.pickNodeID].positionRange?.count ?? 0
                result.append(GraphTransformation(
                    operation: .replace(scope),
                    yield: TransformationYield(
                        structural: activeSize,
                        value: 0,
                        slack: .exact,
                        estimatedProbes: 1
                    ),
                    precondition: .nodeActive(pivotScope.pickNodeID),
                    postcondition: TransformationPostcondition(
                        isStructural: true,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))

            case let .descendantPromotion(promotionScope):
                result.append(GraphTransformation(
                    operation: .replace(scope),
                    yield: TransformationYield(
                        structural: promotionScope.sizeDelta,
                        value: 0,
                        slack: .exact,
                        estimatedProbes: 1
                    ),
                    precondition: .all([
                        .nodeActive(promotionScope.ancestorPickNodeID),
                        .nodeActive(promotionScope.descendantPickNodeID),
                    ]),
                    postcondition: TransformationPostcondition(
                        isStructural: true,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))
            }
        }

        return result
    }

    // MARK: - Minimization

    private static func minimizationTransformations(
        from graph: ChoiceGraph,
        innerChildToBind: [Int: Int]
    ) -> [GraphTransformation] {
        var result: [GraphTransformation] = []

        for scope in graph.minimizationScopes() {
            switch scope {
            case let .integerLeaves(integerScope):
                let maxValueYield = integerScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, computeValueYield(
                        leafNodeID: nodeID,
                        graph: graph,
                        innerChildToBind: innerChildToBind
                    ))
                }
                let maxRange = integerScope.leafNodeIDs.reduce(UInt64(1)) { maxSoFar, nodeID in
                    guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                        return maxSoFar
                    }
                    let rangeSize = (metadata.validRange?.upperBound ?? UInt64.max)
                        &- (metadata.validRange?.lowerBound ?? 0) &+ 1
                    return max(maxSoFar, rangeSize)
                }
                let leafCount = integerScope.leafNodeIDs.count
                let estimatedProbes = 1 + leafCount * ceilLog2(Int(min(maxRange, UInt64(Int.max))))
                result.append(GraphTransformation(
                    operation: .minimize(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: maxValueYield,
                        slack: .exact,
                        estimatedProbes: max(1, estimatedProbes)
                    ),
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))

            case let .floatLeaves(floatScope):
                let maxValueYield = floatScope.leafNodeIDs.reduce(0) { maxSoFar, nodeID in
                    max(maxSoFar, computeValueYield(
                        leafNodeID: nodeID,
                        graph: graph,
                        innerChildToBind: innerChildToBind
                    ))
                }
                result.append(GraphTransformation(
                    operation: .minimize(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: maxValueYield,
                        slack: .exact,
                        estimatedProbes: floatScope.leafNodeIDs.count * 15
                    ),
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))

            case let .kleisliFibre(fibreScope):
                let estimatedProbes = 15 + min(128, fibreScope.boundSubtreeSize)
                result.append(GraphTransformation(
                    operation: .minimize(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: fibreScope.boundSubtreeSize,
                        slack: .exact,
                        estimatedProbes: estimatedProbes
                    ),
                    precondition: .nodeActive(fibreScope.bindNodeID),
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                ))
            }
        }

        return result
    }

    // MARK: - Exchange

    private static func exchangeTransformations(
        from graph: ChoiceGraph,
        innerChildToBind: [Int: Int]
    ) -> [GraphTransformation] {
        var result: [GraphTransformation] = []

        for scope in graph.exchangeScopes() {
            switch scope {
            case let .redistribution(redistScope):
                // Slack: maximum magnitude transferred (source's distance to target).
                let maxSlack = redistScope.pairs.reduce(0) { maxSoFar, pair in
                    guard case let .chooseBits(metadata) = graph.nodes[pair.sourceNodeID].kind else {
                        return maxSoFar
                    }
                    let target = metadata.value.reductionTarget(in: metadata.validRange)
                    let distance = Int(
                        metadata.value.bitPattern64 > target
                            ? metadata.value.bitPattern64 - target
                            : target - metadata.value.bitPattern64
                    )
                    return max(maxSoFar, distance)
                }

                // Enabling yield: walk up containment from each source to find
                // removal candidates in the deletion antichain.
                let antichainSet = Set(graph.deletionAntichain)
                let maxEnablingYield = redistScope.pairs.reduce(0) { maxSoFar, pair in
                    let enabling = computeEnablingYield(
                        sourceNodeID: pair.sourceNodeID,
                        antichainSet: antichainSet,
                        graph: graph
                    )
                    return max(maxSoFar, enabling)
                }

                result.append(GraphTransformation(
                    operation: .exchange(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: maxEnablingYield,
                        slack: AffineSlack(multiplicative: 1, additive: maxSlack),
                        estimatedProbes: min(24, redistScope.pairs.count)
                    ),
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: redistScope.pairs.flatMap {
                            [$0.sourceNodeID, $0.sinkNodeID]
                        },
                        enablesRemoval: []
                    )
                ))

            case let .tandem(tandemScope):
                let groupCount = tandemScope.groups.count
                let maxDistance = tandemScope.groups.reduce(1) { maxSoFar, group in
                    let groupMax = group.leafNodeIDs.reduce(UInt64(1)) { leafMax, nodeID in
                        guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                            return leafMax
                        }
                        let target = metadata.value.reductionTarget(in: metadata.validRange)
                        let distance = metadata.value.bitPattern64 > target
                            ? metadata.value.bitPattern64 - target
                            : target - metadata.value.bitPattern64
                        return max(leafMax, distance)
                    }
                    return max(maxSoFar, Int(min(groupMax, UInt64(Int.max))))
                }
                result.append(GraphTransformation(
                    operation: .exchange(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: 0,
                        slack: AffineSlack(multiplicative: 1, additive: maxDistance),
                        estimatedProbes: groupCount * ceilLog2(maxDistance)
                    ),
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: tandemScope.groups.flatMap(\.leafNodeIDs),
                        enablesRemoval: []
                    )
                ))
            }
        }

        return result
    }

    // MARK: - Permutation

    private static func permutationTransformations(
        from graph: ChoiceGraph
    ) -> [GraphTransformation] {
        graph.permutationScopes().map { scope in
            guard case let .siblingPermutation(permScope) = scope else {
                // PermutationScope currently has only one case.
                return GraphTransformation(
                    operation: .permute(scope),
                    yield: TransformationYield(
                        structural: 0,
                        value: 0,
                        slack: .exact,
                        estimatedProbes: 1
                    ),
                    precondition: .unconditional,
                    postcondition: TransformationPostcondition(
                        isStructural: false,
                        invalidatesConvergence: [],
                        enablesRemoval: []
                    )
                )
            }
            let totalPairs = permScope.swappableGroups.reduce(0) { total, group in
                total + (group.count * (group.count - 1)) / 2
            }
            return GraphTransformation(
                operation: .permute(scope),
                yield: TransformationYield(
                    structural: 0,
                    value: 0,
                    slack: .exact,
                    estimatedProbes: totalPairs
                ),
                precondition: .nodeActive(permScope.zipNodeID),
                postcondition: TransformationPostcondition(
                    isStructural: false,
                    invalidatesConvergence: [],
                    enablesRemoval: []
                )
            )
        }
    }

    // MARK: - Helpers

    /// Builds an index from inner-child node ID to its controlling bind node ID.
    private static func buildInnerChildToBind(from graph: ChoiceGraph) -> [Int: Int] {
        var index: [Int: Int] = [:]
        for node in graph.nodes {
            guard case let .bind(metadata) = node.kind else { continue }
            guard node.children.count >= 2 else { continue }
            let innerChildID = node.children[metadata.innerChildIndex]
            index[innerChildID] = node.id
        }
        return index
    }

    /// Computes value yield for a leaf.
    private static func computeValueYield(
        leafNodeID: Int,
        graph: ChoiceGraph,
        innerChildToBind: [Int: Int]
    ) -> Int {
        guard let bindNodeID = innerChildToBind[leafNodeID] else { return 0 }
        guard case let .bind(metadata) = graph.nodes[bindNodeID].kind else { return 0 }
        guard metadata.isStructurallyConstant == false else { return 0 }
        guard graph.nodes[bindNodeID].children.count >= 2 else { return 0 }
        let boundChildID = graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        return graph.nodes[boundChildID].positionRange?.count ?? 0
    }

    /// Computes enabling yield for a source leaf by walking up the containment
    /// tree to find sequence-element ancestors in the deletion antichain.
    private static func computeEnablingYield(
        sourceNodeID: Int,
        antichainSet: Set<Int>,
        graph: ChoiceGraph
    ) -> Int {
        var yield = 0
        var current = sourceNodeID
        while let parentID = graph.nodes[current].parent {
            if antichainSet.contains(current) {
                yield += graph.nodes[current].positionRange?.count ?? 0
            }
            current = parentID
        }
        return yield
    }

    /// Ceiling of log base 2, with a minimum of 1.
    private static func ceilLog2(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return Int.bitWidth - (value - 1).leadingZeroBitCount
    }
}
