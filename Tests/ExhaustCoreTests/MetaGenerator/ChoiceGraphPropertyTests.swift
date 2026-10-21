import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("ChoiceGraph Construction Properties", .tags(.dogfood))
struct ChoiceGraphPropertyTests {
    @Test("Generated graphs preserve positions, containment and live-node indexing", arguments: recipeSeeds, metaRecipeTypes)
    func graphConstructionContract(seed: UInt64, type: RecipeType) throws {
        try forEachRecipeGraph(seed: seed, type: type) { graph, recipe in
            for leafID in graph.leafNodes {
                #expect(
                    graph.nodes[leafID].positionRange != nil,
                    "Leaf node \(leafID) has nil position range for recipe: \(recipe)"
                )
            }

            let sorted = graph.leafNodes.compactMap { graph.nodes[$0].positionRange }.sorted { $0.lowerBound < $1.lowerBound }
            for (previous, next) in zip(sorted, sorted.dropFirst()) {
                #expect(next.lowerBound > previous.upperBound, "Overlapping leaf ranges for recipe: \(recipe)")
            }

            for (index, node) in graph.nodes.enumerated() {
                for childID in node.children {
                    #expect(
                        graph.nodes[childID].parent == index,
                        "Node \(childID)'s parent is \(String(describing: graph.nodes[childID].parent)) but expected \(index), for recipe: \(recipe)"
                    )
                }
            }

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
    var checkedGraphs = 0
    var checkedLeaves = 0
    var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 2), seed: seed, maxRuns: 30)
    while let recipe = try recipeIter.next() {
        guard recipe.nodeCount <= metaRecipeNodeBudget else {
            continue
        }
        let gen = buildGenerator(from: recipe)
        var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed &+ 1, maxRuns: 5)
        while let (_, tree) = try valueIter.next() {
            let graph = ChoiceGraph.build(from: tree)
            checkedGraphs += 1
            checkedLeaves += graph.leafNodes.count
            try check(graph, recipe)
        }
    }
    #expect(checkedGraphs > 0)
    #expect(checkedLeaves > 0)
}

/// Seeds for the recipe interpreter; each test replays identically across runs while still covering 90 recipes per output type.
private let recipeSeeds: [UInt64] = [1, 42, 9999]
