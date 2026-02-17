////
////  PickSelectionTests.swift
////  Exhaust
////
////  Created by Chris Kolbu on 25/7/2025.
////
//
// import Testing
// @testable import Exhaust
//
// @Suite("Pick Selection Tests")
// struct PickSelectionTests {
//
//    @Test("Boolean arbitrary produces selected branch")
//    func booleanArbitraryProducesSelectedBranch() throws {
//        for _ in 0..<100 {
//            var iterator = ValueInterpreter(Bool.arbitrary)
//            let value = iterator.next()!
//            let recipe = try #require(try Interpreters.reflect(Bool.arbitrary, with: value))
//
//            // The Boolean generator uses Gen.pick, so we should get a group with selected branches
//            guard case let .group(branches) = recipe else {
//                Issue.record("Expected .group for Bool.arbitrary recipe, got \(recipe)")
//                return
//            }
//
//            // There should be exactly one selected branch
//            let selectedBranches = branches.filter { $0.isSelected }
//            #expect(selectedBranches.count == 1, "Expected exactly one selected branch, got \(String(selectedBranches.count))")
//
//            // Verify the selected branch is properly structured
//            let selectedBranch = try #require(selectedBranches.first)
//            guard case let .selected(.branch(label, _, children)) = selectedBranch else {
//                Issue.record("Expected selected branch to contain a .branch, got \(selectedBranch)")
//                return
//            }
//
//            // Label should be 1 or 2 (pick labels are 1-indexed)
//            #expect(label >= 1 && label <= 2, "Expected label 1 or 2 for Boolean pick, got \(label)")
//
//            // Should have a .just child
//            #expect(children.count == 1, "Expected exactly one child in branch")
//            let firstChild = try #require(children.first)
//            #expect(firstChild.isJust, "Expected .just child in Boolean branch")
//        }
//    }
//
//    // FIXME: This crashes now that the Character generator is more complex
//    @Test("Optional Character arbitrary produces selected branch")
//    func optionalCharacterGeneratorProducesSelectedBranch2() throws {
//        let gen = Character?.arbitrary
//        var iterator = ValueInterpreter(gen)
//        let value = iterator.next()!
//        let recipe = try #require(try Interpreters.reflect(gen, with: value))
//        guard case let .group(branches) = recipe else {
//            Issue.record("Expected .group for Character?.arbitrary recipe, got \(recipe)")
//            return
//        }
//        print()
//        #expect(branches.count == 2)
//        #expect(try branches.contains(where: \.isSelected))
//    }
//
//    @Test("Optional Sequence arbitrary produces selected branch")
//    func optionalSequenceGeneratorProducesSelectedBranch2() throws {
//        // TODO: We need a [Bla]?, not a [Bla?]
//    }
//
//    @Test("Optional Int arbitrary produces selected branch")
//    func optionalIntGeneratorProducesSelectedBranch() throws {
//        for _ in 0..<10 {
//            let gen = Int?.arbitrary
//            var iterator = ValueInterpreter(gen)
//            guard let value = iterator.next() else {
//                continue
//            }
//            guard let recipe = try Interpreters.reflect(gen, with: value) else {
//                continue
//            }
//
//            // The Optional generator uses Gen.pick, so we should get a group with selected branches
//            guard case let .group(branches) = recipe else {
//                Issue.record("Expected .group for Int?.arbitrary recipe, got \(recipe)")
//                return
//            }
//
//            // There should be exactly one selected branch
//            let selectedBranches = branches.filter { $0.isSelected }
//            #expect(selectedBranches.count == 1, "Expected exactly one selected branch, got \(String(selectedBranches.count))")
//
//            // Verify the selected branch is properly structured
//            let selectedBranch = try #require(selectedBranches.first)
//            guard case let .selected(.branch(label, _, children)) = selectedBranch else {
//                Issue.record("Expected selected branch to contain a .branch, got \(selectedBranch)")
//                return
//            }
//
//            // Label should be 1 or 2 (pick labels are 1-indexed)
//            #expect(label >= 1 && label <= 2, "Expected label 1 or 2 for Optional pick, got \(label)")
//
//            // Verify the branch content matches the value
//            if value == nil {
//                // .none branch should have a .just child
//                #expect(children.count == 1, "Expected exactly one child for .none branch")
//                let firstChild = try #require(children.first)
//                #expect(firstChild.isJust, "Expected .just child for .none branch")
//            } else {
//                // .some branch should have children representing the wrapped value
//                #expect(!children.isEmpty, "Expected non-empty children for .some branch")
//            }
//        }
//    }
//
//    @Test("Custom pick generator produces selected branch")
//    func customPickGeneratorProducesSelectedBranch() throws {
//        // Create a custom generator using Gen.pick
//        let customGen = Gen.pick(choices: [
//            (1, Gen.just("apple")),
//            (2, Gen.just("banana")),
//            (1, Gen.just("cherry"))
//        ])
//
//        for _ in 0..<100 {
//            var iterator = ValueInterpreter(customGen)
//            let value = iterator.next()!
//            let recipe = try #require(try Interpreters.reflect(customGen, with: value))
//
//            guard case let .group(branches) = recipe else {
//                Issue.record("Expected .group for custom pick recipe, got \(recipe)")
//                return
//            }
//
//            // There should be exactly one selected branch
//            let selectedBranches = branches.filter { $0.isSelected }
//            #expect(selectedBranches.count == 1, "Expected exactly one selected branch, got \(String(selectedBranches.count))")
//
//            // Verify the selected branch corresponds to the generated value
//            let selectedBranch = try #require(selectedBranches.first)
//            guard case let .selected(.branch(label, children)) = selectedBranch else {
//                Issue.record("Expected selected branch to contain a .branch, got \(selectedBranch)")
//                return
//            }
//
//            // Label should be 1, 2, or 3 (pick labels are 1-indexed)
//            #expect(label >= 1 && label <= 3, "Expected label 1-3 for custom pick, got \(label)")
//
//            // Should have a .just child
//            #expect(children.count == 1, "Expected exactly one child in branch")
//            let firstChild = try #require(children.first)
//            #expect(firstChild.isJust, "Expected .just child in custom pick branch")
//        }
//    }
//
//    @Test("Replay with selected branches")
//    func replayWithSelectedBranches() throws {
//        // Test that we can replay a recipe with selected branches
//        var iterator = ValueInterpreter(Bool.arbitrary)
//        let value = iterator.next()!
//        let recipe = try #require(try Interpreters.reflect(Bool.arbitrary, with: value))
//
//        let replayedValue = try #require(try Interpreters.replay(Bool.arbitrary, using: recipe) as Bool?)
//        #expect(value == replayedValue, "Replayed value should match original")
//    }
//
//    @Test("All branches available for shrinking")
//    func allBranchesAvailableForShrinking() throws {
//        // When we deselect for shrinking, all branches should be available
//        let falseValue = false
//        let recipe = try #require(try Interpreters.reflect(Bool.arbitrary, with: falseValue))
//
//        // After deselecting (as done in TieredShrinker), we should have all branches
//        let deselectedRecipe = recipe.map { choice in
//            if case let .selected(selected) = choice {
//                return selected
//            }
//            return choice
//        }
//
//        guard case let .group(branches) = deselectedRecipe else {
//            Issue.record("Expected .group after deselection, got \(deselectedRecipe)")
//            return
//        }
//
//        // Should have both branches (for true and false)
//        let branchLabels = branches.compactMap { branch in
//            if case let .branch(label, _) = branch {
//                return label
//            }
//            return nil
//        }
//
//        #expect(branchLabels.count == 2, "Expected exactly 2 branch labels after deselection, got \(branchLabels.count)")
//        #expect(Set(branchLabels) == Set([1, 2]), "Expected branch labels 1 and 2 after deselection, got \(branchLabels)")
//        #expect(branches.allSatisfy { !$0.isSelected }, "No branches should be selected after deselection")
//    }
// }
