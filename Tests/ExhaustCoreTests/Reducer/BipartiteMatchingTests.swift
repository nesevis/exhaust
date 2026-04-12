//
//  BipartiteMatchingTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

// MARK: - Hopcroft-Karp Tests

@Suite("BipartiteMatching: Hopcroft-Karp")
struct HopcroftKarpTests {
    @Test("Empty graph produces empty matching")
    func emptyGraph() {
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 0,
            rightCount: 0,
            adjacency: []
        )
        #expect(matching.isEmpty)
    }

    @Test("Single edge matches both nodes")
    func singleEdge() {
        // L0 — R0
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 1,
            rightCount: 1,
            adjacency: [[0]]
        )
        #expect(matching == [0])
    }

    @Test("Two independent edges produce a size-2 matching")
    func twoIndependentEdges() {
        // L0 — R0, L1 — R1
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 2,
            rightCount: 2,
            adjacency: [[0], [1]]
        )
        #expect(matching[0] == 0)
        #expect(matching[1] == 1)
    }

    @Test("Competing edges: two left nodes share one right node")
    func competingEdges() {
        // L0 — R0, L1 — R0
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 2,
            rightCount: 1,
            adjacency: [[0], [0]]
        )
        let matchedCount = matching.count(where: { $0 != nil })
        #expect(matchedCount == 1)
    }

    @Test("Augmenting path: initial greedy would miss the optimal matching")
    func augmentingPath() {
        // L0 — R0, R1
        // L1 — R0
        // A naive greedy matching L0→R0 leaves L1 unmatched.
        // Hopcroft-Karp finds the augmenting path L1→R0→L0→R1 for size 2.
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 2,
            rightCount: 2,
            adjacency: [[0, 1], [0]]
        )
        let matchedCount = matching.count(where: { $0 != nil })
        #expect(matchedCount == 2)
    }

    @Test("Complete bipartite K(3,3) has a perfect matching of size 3")
    func completeBipartite3x3() {
        let adjacency = [[0, 1, 2], [0, 1, 2], [0, 1, 2]]
        let size = BipartiteMatching.maximumMatchingSize(
            leftCount: 3,
            rightCount: 3,
            adjacency: adjacency
        )
        #expect(size == 3)
    }

    @Test("Path graph: L0-R0-L1-R1-L2-R2 needs augmenting paths")
    func pathGraph() {
        // L0 — R0
        // L1 — R0, R1
        // L2 — R1, R2
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 3,
            rightCount: 3,
            adjacency: [[0], [0, 1], [1, 2]]
        )
        let matchedCount = matching.count(where: { $0 != nil })
        #expect(matchedCount == 3)
    }

    @Test("No edges produces no matches")
    func noEdges() {
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 3,
            rightCount: 3,
            adjacency: [[], [], []]
        )
        #expect(matching.allSatisfy { $0 == nil })
    }

    @Test("Asymmetric: more left nodes than right")
    func asymmetric() {
        // L0 — R0, L1 — R0, L2 — R1
        let size = BipartiteMatching.maximumMatchingSize(
            leftCount: 3,
            rightCount: 2,
            adjacency: [[0], [0], [1]]
        )
        #expect(size == 2)
    }
}

// MARK: - Minimum Vertex Cover Tests

@Suite("BipartiteMatching: Minimum Vertex Cover")
struct MinimumVertexCoverTests {
    @Test("Cover size equals matching size (Konig's theorem)")
    func coverSizeEqualsMatchingSize() {
        // L0 — R0, R1
        // L1 — R0
        // L2 — R2
        let adjacency = [[0, 1], [0], [2]]
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 3,
            rightCount: 3,
            adjacency: adjacency
        )
        let matchingSize = matching.count(where: { $0 != nil })

        let (leftCover, rightCover) = BipartiteMatching.minimumVertexCover(
            leftCount: 3,
            rightCount: 3,
            adjacency: adjacency,
            matching: matching
        )
        let coverSize = leftCover.count + rightCover.count
        #expect(coverSize == matchingSize)
    }

    @Test("Cover covers all edges")
    func coverCoversAllEdges() {
        let adjacency = [[0, 1], [1, 2], [2]]
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 3,
            rightCount: 3,
            adjacency: adjacency
        )
        let (leftCover, rightCover) = BipartiteMatching.minimumVertexCover(
            leftCount: 3,
            rightCount: 3,
            adjacency: adjacency,
            matching: matching
        )

        // Every edge must have at least one endpoint in the cover.
        for (left, rights) in adjacency.enumerated() {
            for right in rights {
                let covered = leftCover.contains(left) || rightCover.contains(right)
                #expect(covered, "Edge (\(left), \(right)) not covered")
            }
        }
    }

    @Test("Single edge cover")
    func singleEdgeCover() {
        let adjacency = [[0]]
        let matching = BipartiteMatching.hopcroftKarp(
            leftCount: 1,
            rightCount: 1,
            adjacency: adjacency
        )
        let (leftCover, rightCover) = BipartiteMatching.minimumVertexCover(
            leftCount: 1,
            rightCount: 1,
            adjacency: adjacency,
            matching: matching
        )
        #expect(leftCover.count + rightCover.count == 1)
    }
}

// MARK: - Maximum Antichain (Dilworth) Tests

@Suite("BipartiteMatching: Maximum Antichain")
struct MaximumAntichainTests {
    @Test("Total order: antichain is size 1")
    func totalOrder() {
        // Chain: 0 → 1 → 2
        let reachability: [Int: Set<Int>] = [
            0: [1, 2],
            1: [2],
            2: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 3,
            reachability: reachability
        )
        #expect(antichain.count == 1)
    }

    @Test("No edges: antichain is all nodes")
    func noEdges() {
        // Three independent nodes — all are in the antichain.
        let reachability: [Int: Set<Int>] = [
            0: [],
            1: [],
            2: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 3,
            reachability: reachability
        )
        #expect(antichain.count == 3)
        #expect(Set(antichain) == [0, 1, 2])
    }

    @Test("Diamond DAG: antichain is the two middle nodes")
    func diamondDAG() {
        //     0
        //    / \
        //   1   2
        //    \ /
        //     3
        let reachability: [Int: Set<Int>] = [
            0: [1, 2, 3],
            1: [3],
            2: [3],
            3: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 4,
            reachability: reachability
        )
        #expect(antichain.count == 2)
        #expect(Set(antichain) == [1, 2])
    }

    @Test("Two independent chains: antichain picks one from each")
    func twoChains() {
        // Chain A: 0 → 1
        // Chain B: 2 → 3
        let reachability: [Int: Set<Int>] = [
            0: [1],
            1: [],
            2: [3],
            3: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 4,
            reachability: reachability
        )
        #expect(antichain.count == 2)
        // Each chain contributes exactly one member.
        let antichainSet = Set(antichain)
        let fromChainA = antichainSet.intersection([0, 1])
        let fromChainB = antichainSet.intersection([2, 3])
        #expect(fromChainA.count == 1)
        #expect(fromChainB.count == 1)
    }

    @Test("W-shaped DAG: wider antichain than greedy finds")
    func wShapedDAG() {
        //   0   1
        //   |\ /|
        //   | X |
        //   |/ \|
        //   2   3
        // 0 reaches 2, 3; 1 reaches 2, 3. No edge between 0 and 1, no edge between 2 and 3.
        let reachability: [Int: Set<Int>] = [
            0: [2, 3],
            1: [2, 3],
            2: [],
            3: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 4,
            reachability: reachability
        )
        // Maximum antichain is {0, 1} or {2, 3} — both size 2.
        #expect(antichain.count == 2)
        let antichainSet = Set(antichain)
        let valid = antichainSet == [0, 1] || antichainSet == [2, 3]
        #expect(valid, "Expected {0,1} or {2,3}, got \(antichainSet)")
    }

    @Test("Single node: antichain is that node")
    func singleNode() {
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 1,
            reachability: [0: []]
        )
        #expect(antichain == [0])
    }

    @Test("Empty DAG: antichain is empty")
    func emptyDAG() {
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 0,
            reachability: [:]
        )
        #expect(antichain.isEmpty)
    }

    @Test("Antichain members are pairwise independent")
    func pairwiseIndependence() {
        // Five nodes: 0→2, 0→3, 1→3, 1→4
        let reachability: [Int: Set<Int>] = [
            0: [2, 3],
            1: [3, 4],
            2: [],
            3: [],
            4: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 5,
            reachability: reachability
        )
        // Verify pairwise independence: no member reaches any other member.
        for memberA in antichain {
            let reachable = reachability[memberA] ?? []
            for memberB in antichain where memberA != memberB {
                #expect(
                    reachable.contains(memberB) == false,
                    "Antichain member \(memberA) reaches \(memberB)"
                )
            }
        }
    }

    @Test("Three independent chains of length 3: antichain is size 3")
    func threeIndependentChains() {
        // Chain A: 0 → 1 → 2
        // Chain B: 3 → 4 → 5
        // Chain C: 6 → 7 → 8
        let reachability: [Int: Set<Int>] = [
            0: [1, 2], 1: [2], 2: [],
            3: [4, 5], 4: [5], 5: [],
            6: [7, 8], 7: [8], 8: [],
        ]
        let antichain = BipartiteMatching.maximumAntichain(
            nodeCount: 9,
            reachability: reachability
        )
        #expect(antichain.count == 3)
    }
}
