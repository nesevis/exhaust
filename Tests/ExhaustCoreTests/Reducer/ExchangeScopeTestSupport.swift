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
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            graph.convergenceStore[nodeID] = ConvergedOrigin(bound: metadata.value.bitPattern64, signal: .monotoneConvergence, configuration: .binarySearchSemanticSimplest, cycle: 0)
        }
        return graph
    }
}
