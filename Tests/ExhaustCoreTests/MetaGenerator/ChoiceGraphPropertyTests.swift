import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("ChoiceGraph Construction Properties", .tags(.dogfood))
struct ChoiceGraphPropertyTests {
    @Test("Every leaf node has a non-nil position range", arguments: recipeSeeds, metaRecipeTypes)
    func leafNodesHavePositions(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
            for leafID in graph.leafNodes {
                #expect(
                    graph.nodes[leafID].positionRange != nil,
                    "Leaf node \(leafID) has nil position range for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Position ranges of leaf nodes are non-overlapping", arguments: recipeSeeds, metaRecipeTypes)
    func positionRangesNonOverlapping(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
            let ranges = graph.leafNodes.compactMap { graph.nodes[$0].positionRange }
            guard ranges.count >= 2 else {
                return
            }
            let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
            for index in 1 ..< sorted.count {
                #expect(
                    sorted[index].lowerBound > sorted[index - 1].upperBound,
                    "Overlapping position ranges at index \(index) for recipe: \(recipe)"
                )
            }
        }
    }

    @Test("Parent links are consistent with children links", arguments: recipeSeeds, metaRecipeTypes)
    func parentChildConsistency(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
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

    @Test("Topological order contains no duplicates and all entries are valid node IDs", arguments: recipeSeeds, metaRecipeTypes)
    func topologicalOrderValid(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
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

    @Test("Live node IDs reference valid nodes with non-nil position ranges", arguments: recipeSeeds, metaRecipeTypes)
    func liveNodeIDsValid(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
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

// MARK: - Helpers

/// Runs the check over every (graph, recipe) pair produced by depth-2 recipes of the given type: 30 budget-guarded recipes, five trees each.
private func forEachRecipeGraph(
    seed: UInt64,
    type: RecipeType,
    check: (ChoiceGraph, GenRecipe) throws -> Void
) throws {
    var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 2), seed: seed, maxRuns: 30)
    while let recipe = try recipeIter.next() {
        guard recipe.nodeCount <= metaRecipeNodeBudget else {
            continue
        }
        let gen = buildGenerator(from: recipe)
        var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed &+ 1, maxRuns: 5)
        while let (_, tree) = try valueIter.next() {
            try check(ChoiceGraph.build(from: tree), recipe)
        }
    }
}

/// Seeds for the recipe interpreter; each test replays identically across runs while still covering 90 recipes per output type.
private let recipeSeeds: [UInt64] = [1, 42, 9999]
