import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Replacement discovery", .tags(.dogfood))
struct ScopeSourceDifferentialTests {
    @Test("Replacement discovery preserves the eager oracle's scopes and order", arguments: [UInt64(1), 42, 9999], metaRecipeTypes)
    func replacementDiscoveryMatchesEagerOracle(seed: UInt64, type: RecipeType) throws {
        var recipes = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 3), seed: seed, maxRuns: 30)
        var compared = 0
        while let recipe = try recipes.next() {
            guard recipe.nodeCount <= metaRecipeNodeBudget else {
                continue
            }
            var values = ValueAndChoiceTreeInterpreter(buildGenerator(from: recipe), materializePicks: true, seed: seed &+ 1, maxRuns: 5)
            while let (_, tree) = try values.next() {
                let graph = ChoiceGraph.build(from: tree)
                let expected = EagerScopeReference.replacementScopes(graph: graph)
                let actual = replacementScopes(graph: graph)
                #expect(actual.map(signature) == expected.map(signature), "Replacement discovery differs for recipe: \(recipe)")

                let expectedIncremental = EagerScopeReference.replacementScopes(graph: graph, previousGraph: graph)
                let actualIncremental = replacementScopes(graph: graph, previousGraph: graph)
                #expect(actualIncremental.map(signature) == expectedIncremental.map(signature), "Incremental discovery differs for recipe: \(recipe)")
                compared += 1
            }
        }
        #expect(compared > 0)
    }
}

// MARK: - Helpers

/// Compares scope identities without adding equality requirements to production types.
private func signature(_ scope: ReplacementScope) -> String {
    switch scope {
        case let .selfSimilar(targetNodeID, donorNodeID, sizeDelta):
            "selfSimilar \(targetNodeID) \(donorNodeID) \(sizeDelta)"
        case let .branchPivot(pickNodeID, targetBranchID):
            "branchPivot \(pickNodeID) \(targetBranchID)"
        case let .descendantPromotion(ancestorPickNodeID, descendantPickNodeID, sizeDelta):
            "descendantPromotion \(ancestorPickNodeID) \(descendantPickNodeID) \(sizeDelta)"
    }
}
