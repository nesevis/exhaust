import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ChoiceGraph bind-rooted build", .tags(.dogfood))
struct ChoiceGraphBindBuildPropertyTests {
    @Test("A bind-rooted build reproduces the full build's subtree under every bind it accepts", arguments: bindRecipeSeeds, metaRecipeTypes)
    func bindRootedBuildMatchesFullSubtree(seed: UInt64, type: RecipeType) throws {
        var comparedBinds = 0
        try forEachRecipeTree(seed: seed, type: type) { tree, recipe in
            let full = ChoiceGraph.build(from: tree)
            for bindNodeID in full.liveNodeIDs {
                guard case let .bind(metadata) = full.nodes[bindNodeID].kind else {
                    continue
                }
                let bindRooted = ChoiceGraphBuilder.buildBind(
                    at: metadata.bindPath,
                    fingerprint: metadata.fingerprint,
                    in: tree,
                    omittingScalarSequenceElements: false
                )
                guard metadata.bindPath.contains(.bindInner) == false else {
                    #expect(bindRooted == nil, "A bind inside another bind's inner subtree must fall back, for recipe: \(recipe)")
                    continue
                }
                let built = try #require(bindRooted, "No bind-rooted build at \(metadata.bindPath) for recipe: \(recipe)")
                #expect(built.bindNodeID == 0)
                expectSubtreesMatch(full: full, fullRootID: bindNodeID, bindRooted: built.graph, recipe: recipe)
                comparedBinds += 1
            }
        }
        #expect(comparedBinds > 0, "No recipe produced a bind to compare")
    }
}

// MARK: - Helpers

/// Seeds for the recipe interpreter, as in ``ChoiceGraphPropertyTests``.
private let bindRecipeSeeds: [UInt64] = [1, 42, 9999]

private func forEachRecipeTree(
    seed: UInt64,
    type: RecipeType,
    check: (ChoiceTree, GenRecipe) throws -> Void
) throws {
    var recipeIter = ValueInterpreter(recipeGenerator(producing: type, maxDepth: 3), seed: seed, maxRuns: 30)
    while let recipe = try recipeIter.next() {
        guard recipe.nodeCount <= metaRecipeNodeBudget else {
            continue
        }
        let gen = buildGenerator(from: recipe)
        var valueIter = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed &+ 1, maxRuns: 5)
        while let (_, tree) = try valueIter.next() {
            try check(tree, recipe)
        }
    }
}

/// Compares the full build's subtree rooted at `fullRootID` with the bind-rooted graph, node by node. Both builds emit nodes in walk order, so the subtree's IDs are contiguous from the root in the full graph and from zero in the bind-rooted one.
private func expectSubtreesMatch(full: ChoiceGraph, fullRootID: Int, bindRooted: ChoiceGraph, recipe: GenRecipe) {
    var subtreeIDs: [Int] = []
    var stack = [fullRootID]
    while let nodeID = stack.popLast() {
        subtreeIDs.append(nodeID)
        stack.append(contentsOf: full.nodes[nodeID].children)
    }
    subtreeIDs.sort()
    #expect(subtreeIDs == Array(fullRootID ..< fullRootID + subtreeIDs.count), "Subtree IDs are not contiguous for recipe: \(recipe)")
    #expect(bindRooted.nodes.count == subtreeIDs.count, "Node counts differ for recipe: \(recipe)")
    guard bindRooted.nodes.count == subtreeIDs.count else {
        return
    }
    for localID in bindRooted.nodes.indices {
        let fullNode = full.nodes[fullRootID + localID]
        let localNode = bindRooted.nodes[localID]
        #expect(localNode.positionRange == fullNode.positionRange, "Position of node \(localID) differs for recipe: \(recipe)")
        #expect(localNode.choicePath == fullNode.choicePath, "Path of node \(localID) differs for recipe: \(recipe)")
        #expect(localNode.children == fullNode.children.map { $0 - fullRootID }, "Children of node \(localID) differ for recipe: \(recipe)")
        #expect(localNode.scopeAnnotation.isBindInner == fullNode.scopeAnnotation.isBindInner, "Bind role of node \(localID) differs for recipe: \(recipe)")
        #expect(localNode.scopeAnnotation.controllingBindDepth == fullNode.scopeAnnotation.controllingBindDepth, "Controlling depth of node \(localID) differs for recipe: \(recipe)")
        #expect(localNode.scopeAnnotation.controllingBindNodeID == fullNode.scopeAnnotation.controllingBindNodeID.map { $0 - fullRootID }, "Controlling bind of node \(localID) differs for recipe: \(recipe)")
        #expect(kindSummary(localNode.kind) == kindSummary(fullNode.kind), "Kind of node \(localID) differs for recipe: \(recipe)")
    }
    #expect(bindRooted.leafNodes == full.leafNodes.filter { subtreeIDs.contains($0) }.map { $0 - fullRootID }, "Leaf nodes differ for recipe: \(recipe)")
}

/// The fields of a node kind that do not refer to node IDs.
private func kindSummary(_ kind: ChoiceGraphNodeKind) -> String {
    switch kind {
        case let .chooseBits(metadata):
            "chooseBits \(metadata.value) \(String(describing: metadata.validRange))"
        case let .sequence(metadata):
            "sequence \(metadata.elementCount) \(metadata.childPositionRanges) \(String(describing: metadata.lengthConstraint))"
        case let .bind(metadata):
            "bind \(metadata.fingerprint) \(metadata.isStructurallyConstant) \(metadata.bindDepth) \(metadata.bindPath)"
        case let .pick(metadata):
            "pick \(metadata.fingerprint) \(metadata.selectedID) \(metadata.branchCount) \(metadata.selectedChildIndex)"
        case .zip:
            "zip"
        case .just:
            "just"
    }
}
