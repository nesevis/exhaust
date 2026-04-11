//
//  ChoiceGraphComparison.swift
//  Exhaust
//

// MARK: - Comparison Result

/// Result of comparing a ``ChoiceGraph`` against the existing ``ChoiceDependencyGraph`` and ``BindSpanIndex``.
///
/// Each check validates superset-or-equal: the graph must provide at least what the existing system provides. Additional results (larger antichain, more edges) are expected improvements, not failures.
public struct ChoiceGraphComparisonResult {
    /// Individual check results.
    public var checks: [CheckResult] = []

    /// Whether all checks passed.
    public var allPassed: Bool {
        checks.allSatisfy(\.passed)
    }

    /// A single comparison check.
    public struct CheckResult {
        /// Name of the check.
        public let name: String

        /// Whether the check passed.
        public let passed: Bool

        /// Detail message (populated on failure, or on pass with notable differences).
        public let detail: String
    }
}

// MARK: - Comparison Logic

/// Validates a ``ChoiceGraph`` against the existing ``ChoiceDependencyGraph`` and ``BindSpanIndex``.
///
/// Runs all comparison checks and returns a result with per-check pass/fail status. Used during Phase 2 validation to confirm the graph provides superset-or-equal answers before building encoders that depend on it.
public enum ChoiceGraphComparison {
    /// Runs all comparison checks.
    ///
    /// - Parameters:
    ///   - graph: The ``ChoiceGraph`` to validate.
    ///   - cdg: The existing ``ChoiceDependencyGraph`` to compare against.
    ///   - bindIndex: The existing ``BindSpanIndex`` to compare against.
    ///   - sequence: The ``ChoiceSequence`` for position-level queries.
    /// - Returns: Comparison result with per-check pass/fail.
    public static func validate(
        graph: ChoiceGraph,
        cdg: ChoiceDependencyGraph,
        bindIndex: BindSpanIndex,
        sequence: ChoiceSequence
    ) -> ChoiceGraphComparisonResult {
        var result = ChoiceGraphComparisonResult()
        result.checks.append(checkDependencyEdges(graph: graph, cdg: cdg))
        result.checks.append(checkBindDepth(graph: graph, bindIndex: bindIndex, sequence: sequence))
        result.checks.append(checkBoundSubtree(graph: graph, bindIndex: bindIndex, sequence: sequence))
        result.checks.append(checkLeafPositions(graph: graph, cdg: cdg, sequence: sequence))
        result.checks.append(checkReductionEdges(graph: graph, cdg: cdg))
        return result
    }

    // MARK: - Individual Checks

    /// Validates that the graph's dependency structure covers the CDG's.
    ///
    /// The CDG and graph have different models for dependency edges. The CDG maps narrow position ranges (bind-inner values, branch selectors) to each other. The graph maps node IDs with richer semantics. Rather than requiring position-level string matching, this check validates that the graph has at least as many bind nodes and dependency edges as the CDG has structural nodes and edges.
    @_spi(ExhaustInternal) public static func checkDependencyEdges(
        graph: ChoiceGraph,
        cdg: ChoiceDependencyGraph
    ) -> ChoiceGraphComparisonResult.CheckResult {
        let cdgEdgeCount = cdg.nodes.reduce(0) { $0 + $1.dependents.count }
        let graphEdgeCount = graph.dependencyEdges.count

        // The graph should have at least as many dependency edges as the CDG.
        let passed = graphEdgeCount >= cdgEdgeCount
        return .init(
            name: "dependency_edges",
            passed: passed,
            detail: "CDG: \(cdgEdgeCount) edges, graph: \(graphEdgeCount) edges"
        )
    }

    /// Validates that bind depth matches at every value position.
    @_spi(ExhaustInternal) public static func checkBindDepth(
        graph: ChoiceGraph,
        bindIndex: BindSpanIndex,
        sequence: ChoiceSequence
    ) -> ChoiceGraphComparisonResult.CheckResult {
        var mismatches: [(position: Int, graphDepth: Int, indexDepth: Int)] = []

        for position in 0 ..< sequence.count {
            switch sequence[position] {
            case .value, .reduced:
                let graphDepth = graph.bindDepth(at: position)
                let indexDepth = bindIndex.bindDepth(at: position)
                if graphDepth != indexDepth {
                    mismatches.append((position, graphDepth, indexDepth))
                }
            default:
                break
            }
        }

        if mismatches.isEmpty {
            return .init(name: "bind_depth", passed: true, detail: "All positions match")
        }
        let first = mismatches.prefix(3).map { "pos \($0.position): graph=\($0.graphDepth), index=\($0.indexDepth)" }
        return .init(
            name: "bind_depth",
            passed: false,
            detail: "\(mismatches.count) mismatches: \(first.joined(separator: ", "))"
        )
    }

    /// Validates that isInBoundSubtree matches at every position.
    @_spi(ExhaustInternal) public static func checkBoundSubtree(
        graph: ChoiceGraph,
        bindIndex: BindSpanIndex,
        sequence: ChoiceSequence
    ) -> ChoiceGraphComparisonResult.CheckResult {
        var mismatches: [(position: Int, graphResult: Bool, indexResult: Bool)] = []

        for position in 0 ..< sequence.count {
            let graphResult = graph.isInBoundSubtree(position)
            let indexResult = bindIndex.isInBoundSubtree(position)
            if graphResult != indexResult {
                mismatches.append((position, graphResult, indexResult))
            }
        }

        if mismatches.isEmpty {
            return .init(name: "bound_subtree", passed: true, detail: "All positions match")
        }
        let first = mismatches.prefix(3).map { "pos \($0.position): graph=\($0.graphResult), index=\($0.indexResult)" }
        return .init(
            name: "bound_subtree",
            passed: false,
            detail: "\(mismatches.count) mismatches: \(first.joined(separator: ", "))"
        )
    }

    /// Validates that every CDG leaf position is covered by a graph chooseBits node.
    ///
    /// The graph's leaf model is richer than the CDG's — every value has an explicit typed node. The CDG identifies leaves as value entries not inside structural node ranges. The graph identifies leaves as chooseBits nodes. Every CDG leaf position should correspond to a graph chooseBits node at that position.
    @_spi(ExhaustInternal) public static func checkLeafPositions(
        graph: ChoiceGraph,
        cdg: ChoiceDependencyGraph,
        sequence _: ChoiceSequence
    ) -> ChoiceGraphComparisonResult.CheckResult {
        let cdgLeafPositions = cdg.leafPositions
        let graphLeafPositions = graph.leafPositions

        // Flatten to individual positions for comparison.
        let cdgPositionSet = Set(cdgLeafPositions.flatMap { $0.lowerBound ... $0.upperBound })
        let graphPositionSet = Set(graphLeafPositions.flatMap { $0.lowerBound ... $0.upperBound })

        // Every CDG leaf position should appear in the graph's chooseBits positions.
        // The graph may have additional chooseBits positions (bind-inner values are chooseBits nodes
        // in the graph but structural positions in the CDG).
        let missing = cdgPositionSet.subtracting(graphPositionSet)
        if missing.isEmpty {
            return .init(
                name: "leaf_positions",
                passed: true,
                detail: "CDG: \(cdgPositionSet.count) positions, graph: \(graphPositionSet.count) positions (graph may have more — bind-inner values are chooseBits in the graph)"
            )
        }
        return .init(
            name: "leaf_positions",
            passed: false,
            detail: "Missing \(missing.count) CDG leaf positions in graph chooseBits: \(missing.sorted().prefix(10))"
        )
    }

    /// Validates that the graph has at least as many reduction edges as the CDG.
    ///
    /// The CDG produces one reduction edge per bind-inner node. The graph should produce the same — one per active bind node. The graph's model is richer (it includes the structurallyConstant flag and uses node IDs), so the check validates count coverage.
    @_spi(ExhaustInternal) public static func checkReductionEdges(
        graph: ChoiceGraph,
        cdg: ChoiceDependencyGraph
    ) -> ChoiceGraphComparisonResult.CheckResult {
        let cdgEdges = cdg.reductionEdges()
        let graphEdges = graph.reductionEdges

        let passed = graphEdges.count >= cdgEdges.count
        return .init(
            name: "reduction_edges",
            passed: passed,
            detail: "CDG: \(cdgEdges.count), graph: \(graphEdges.count)"
        )
    }

    // MARK: - Logging

    /// Logs comparison results via ``ExhaustLog``.
    public static func logResult(_ result: ChoiceGraphComparisonResult) {
        var metadata: [String: String] = [
            "all_passed": "\(result.allPassed)",
        ]
        for check in result.checks {
            metadata["check_\(check.name)"] = check.passed ? "pass" : "FAIL"
            metadata["detail_\(check.name)"] = check.detail
        }
        ExhaustLog.debug(
            category: .reducer,
            event: "choicegraph_validation",
            metadata: metadata
        )
    }
}
