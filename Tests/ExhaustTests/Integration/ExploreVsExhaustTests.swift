//
//  ExploreVsExhaustTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust

@Suite("Explore vs Exhaust")
struct ExploreVsExhaustTests {
    // MARK: - #exhaust baseline

    @Test("#exhaust finds a valid BST with height exactly 5", .disabled("Stack overflow"))
    func exhaustFindsHeight5BST() throws {
        let gen = BST.arbitraryRecursive(valueRange: 0 ... 18)
            .unique()
            .filter { $0.isValidBST() }
        
        let result = #exhaust(
            gen,
            .budget(.expensive),
            .replay(577118919570660442),
            .suppressIssueReporting
        ) { bst in
            !(bst.height == 5)
        }
        let bst = try #require(result)
        #expect(bst.height == 5)
        #expect(bst.isValidBST())
    }

    // MARK: - Hill-climbing #explore

    @Test("#explore with scorer finds deep valid BSTs")
    func exploreWithScorerFindsDeepBSTs() throws {
        let gen = BST.arbitrary(maxDepth: 5, valueRange: 1 ... 18)
            .filter { $0.isValidBST() }
            .unique()

        // Composite scorer: reward height
        // Height alone doesn't guide toward valid BSTs — most tall trees violate ordering.
        let result = #explore(
            gen,
            .samplingBudget(200_000),
            .replay(15_190_352_305_301_843_617),
            .suppressIssueReporting,
            scorer: { Double($0.height) })
        { bst in
            !(bst.height >= 5)
        }

        let bst = try #require(result)
        #expect(bst.height >= 5)
        #expect(bst.isValidBST())
    }

    // MARK: - Basic #explore

    @Test("#explore with scorer works for simple search")
    func exploreWithScorerWorks() {
        let gen = #gen(.int(in: 0 ... 1000))
        let result = #explore(gen, .samplingBudget(500), .suppressIssueReporting,
                              scorer: { Double($0) })
        { value in
            value < 500
        }
        #expect(result != nil)
        if let ce = result {
            #expect(ce >= 500)
        }
    }
}
