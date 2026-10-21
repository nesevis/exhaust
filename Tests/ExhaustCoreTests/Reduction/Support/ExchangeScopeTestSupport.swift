//
//  ExchangeScopeTestSupport.swift
//  Exhaust
//

@testable import ExhaustCore

extension [ExchangeScope] {
    /// The tandem scope among these scopes. ``ExchangeQuery/build(graph:)`` emits at most one.
    var tandemScope: TandemScope? {
        for scope in self {
            if case let .tandem(tandemScope) = scope {
                return tandemScope
            }
        }
        return nil
    }
}

extension RedistributionScope {
    /// Materializes the pair stream only for test assertions and eager reference paths; production consumers use ``pairCursor()``.
    var pairs: [RedistributionPair] {
        var cursor = pairCursor()
        var result: [RedistributionPair] = []
        result.reserveCapacity(pairCount)
        while let pair = cursor.next() {
            result.append(pair)
        }
        return result
    }
}

extension ChoiceGraph {
    /// Builds the graph with every leaf certified at its current value, the state the relation pass requires before it considers a leaf.
    static func stalled(from tree: ChoiceTree) -> ChoiceGraph {
        var graph = ChoiceGraph.build(from: tree)
        graph.markLeavesConverged()
        return graph
    }

    /// Certifies each value leaf at its current value without replacing the graph's other state.
    mutating func markLeavesConverged() {
        for nodeID in leafNodes {
            guard case let .chooseBits(metadata) = nodes[nodeID].kind else {
                continue
            }
            convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
    }
}

extension StagedJointQuery.Groups {
    var estimatedWork: Int {
        groups.reduce(0) { $0 + $1.estimatedWork }
    }
}
