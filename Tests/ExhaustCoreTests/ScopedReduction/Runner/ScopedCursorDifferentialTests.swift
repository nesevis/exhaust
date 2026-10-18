import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped structural cursor references")
struct ScopedCursorDifferentialTests {
    @Test("Improving pivots retain the eager stream's fill eligibility and stable length order")
    func improvingPivotsMatchEagerReference() {
        let tree = mixedPivots()
        let sequence = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        var seen: Set<UInt64> = []
        let expected = EagerScopeReference.improvingPivotCandidates(sequence: sequence, graph: graph).filter {
            seen.insert(ZobristHash.hash(of: $0)).inserted
        }
        var cursor = ScopedImprovingPivotCursor(sequence: sequence, incumbentHash: ZobristHash.hash(of: sequence), graph: graph, rejectCache: [], deadline: .none)
        var actual: [ChoiceSequence] = []
        while let probe = cursor.next() {
            #expect(probe.probeHash == ZobristHash.hash(of: probe.sequence))
            actual.append(probe.sequence)
        }

        #expect(expected.isEmpty == false)
        #expect(actual == expected)
        #expect(cursor.next() == nil)
    }

    @Test("The relax cursor retains the eager stable prefix within its budget", arguments: [0, 1, 3, 32])
    func relaxPrefixMatchesEagerReference(limit: Int) {
        let tree = mixedPivots()
        let sequence = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        let expected = EagerScopeReference.relaxCandidates(sequence: sequence, graph: graph)
        var cursor = ScopedRelaxCandidateCursor(sequence: sequence, graph: graph, limit: limit)
        var actual: [ChoiceSequence] = []
        while let candidate = cursor.next() {
            actual.append(candidate)
        }

        #expect(expected.isEmpty == false)
        #expect(cursor.candidateCount == expected.count)
        #expect(actual == Array(expected.prefix(limit)))
        #expect(cursor.next() == nil)
    }
}

// MARK: - Test helpers

/// Exercises length ties, shorter arms, and an arm with fewer leaves whose framing prevents a length improvement.
private func mixedPivots() -> ChoiceTree {
    .group([
        .pickSite(fingerprint: 42, selected: 1, branches: [.uint64(2, in: 0 ... 10), .uint64(5, in: 0 ... 10)]),
        .pickSite(fingerprint: 43, selected: 1, branches: [.uint64(9, in: 0 ... 10), .uint64Zip([5, 6], in: 0 ... 10)]),
        .pickSite(fingerprint: 44, selected: 1, branches: [.uint64(10, in: 0 ... 100), .uint64(250, in: 200 ... 300)]),
        .pickSite(fingerprint: 45, selected: 1, branches: [.sequence(elements: [.uint64(1, in: 0 ... 10)], metadata: .init(validRange: nil)), .uint64(5, in: 0 ... 10)]),
    ])
}
