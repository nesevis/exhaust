import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("ChoiceGraph Construction Properties", .tags(.dogfood))
struct ChoiceGraphPropertyTests {
    private let intRecipeGen = recipeGenerator(producing: .int, maxDepth: 1)

    @Test("Every leaf node has a non-nil position range")
    func leafNodesHavePositions() throws {
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, maxRuns: 5)
            while let (_, tree) = try valueIter.next() {
                let graph = ChoiceGraph.build(from: tree)
                for leafID in graph.leafNodes {
                    #expect(
                        graph.nodes[leafID].positionRange != nil,
                        "Leaf node \(leafID) has nil position range for recipe: \(recipe)"
                    )
                }
            }
        }
    }

    @Test("Position ranges of leaf nodes are non-overlapping")
    func positionRangesNonOverlapping() throws {
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, maxRuns: 5)
            while let (_, tree) = try valueIter.next() {
                let graph = ChoiceGraph.build(from: tree)
                let ranges = graph.leafNodes.compactMap { graph.nodes[$0].positionRange }
                guard ranges.count >= 2 else { continue }
                let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
                for index in 1 ..< sorted.count {
                    #expect(
                        sorted[index].lowerBound > sorted[index - 1].upperBound,
                        "Overlapping position ranges at index \(index) for recipe: \(recipe)"
                    )
                }
            }
        }
    }

    @Test("Parent links are consistent with children links")
    func parentChildConsistency() throws {
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, maxRuns: 5)
            while let (_, tree) = try valueIter.next() {
                let graph = ChoiceGraph.build(from: tree)
                for (index, node) in graph.nodes.enumerated() {
                    for childID in node.children {
                        #expect(
                            graph.nodes[childID].parent == index,
                            "Node \(childID)'s parent is \(String(describing: graph.nodes[childID].parent)) but expected \(index), for recipe: \(recipe)"
                        )
                    }
                }
            }
        }
    }

    @Test("Topological order contains no duplicates and all entries are valid node IDs")
    func topologicalOrderValid() throws {
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, maxRuns: 5)
            while let (_, tree) = try valueIter.next() {
                let graph = ChoiceGraph.build(from: tree)
                let orderSet = Set(graph.topologicalOrder)
                #expect(
                    orderSet.count == graph.topologicalOrder.count,
                    "Topological order has duplicates for recipe: \(recipe)"
                )
                for nodeID in graph.topologicalOrder {
                    #expect(
                        nodeID >= 0 && nodeID < graph.nodes.count,
                        "Topological order contains invalid node ID \(nodeID) for recipe: \(recipe)"
                    )
                }
            }
        }
    }

    @Test("Live node IDs reference valid nodes with non-nil position ranges")
    func liveNodeIDsValid() throws {
        var recipeIter = ValueInterpreter(intRecipeGen, maxRuns: 30)
        while let recipe = try recipeIter.next() {
            let gen = buildGenerator(from: recipe)
            var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, maxRuns: 5)
            while let (_, tree) = try valueIter.next() {
                let graph = ChoiceGraph.build(from: tree)
                for nodeID in graph.liveNodeIDs {
                    #expect(
                        nodeID >= 0 && nodeID < graph.nodes.count,
                        "liveNodeIDs contains invalid ID \(nodeID) for recipe: \(recipe)"
                    )
                    #expect(
                        graph.nodes[nodeID].positionRange != nil,
                        "Live node \(nodeID) has nil position range for recipe: \(recipe)"
                    )
                }
            }
        }
    }
}
