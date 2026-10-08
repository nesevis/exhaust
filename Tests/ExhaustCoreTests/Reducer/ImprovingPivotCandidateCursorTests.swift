import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Improving pivot candidate cursor")
struct ImprovingPivotCandidateCursorTests {
    @Test("A non-improving recorded fill suppresses farthest but allows an improving transplant")
    func transplantAfterNonImprovingRecordedFill() throws {
        let target = ChoiceTree.group([leaf(2, range: 0 ... 3), leaf(2, range: 0 ... 3)], isZip: true)
        let selected = ChoiceTree.group([leaf(1, range: 0 ... 10), leaf(8, range: 0 ... 10)], isZip: true)
        let tree = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [target, selected])
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        let pickNodeID = try #require(graph.liveNodeIDs.first { nodeID in
            if case .pick = graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        let recorded = try #require(GraphStructuralEncoder.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: 0, fill: .recorded, sequence: sequence, graph: graph))
        let transplanted = try #require(GraphStructuralEncoder.branchPivotCandidate(pickNodeID: pickNodeID, targetBranchID: 0, fill: .transplanted, sequence: sequence, graph: graph))
        #expect(recorded.shortLexPrecedes(sequence) == false)
        #expect(transplanted.shortLexPrecedes(sequence))
        var cursor = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: [])
        let first = cursor.next()
        #expect(first?.sequence == transplanted)
        #expect(cursor.constructedCandidateCount == 2)
        #expect(cursor.next() == nil)
    }

    @Test("Wide preparation stores descriptors and constructs only requested complete sequences")
    func widePreparation() throws {
        let tree = ChoiceTree.group((0 ..< 400).map { _ in
            ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [leaf(10, range: 0 ... 100), leaf(250, range: 200 ... 300)])
        })
        let graph = ChoiceGraph.build(from: tree)
        let sequence = ChoiceSequence(tree)
        var cursor = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: [])
        #expect(cursor.preparedPivotCount == 400)
        #expect(cursor.constructedCandidateCount == 0)
        for _ in 0 ..< 2 {
            let next = cursor.next()
            let probe = try #require(next)
            #expect(probe.sequence.shortLexPrecedes(sequence))
        }
        #expect(cursor.constructedCandidateCount == 2)
    }

    @Test("A fully cached stream exhausts without returning a candidate")
    func cacheExhaustion() {
        let fixture = mixedPivots()
        let rejected = Set(EagerScopeReference.improvingPivotCandidates(sequence: fixture.sequence, graph: fixture.graph).map { ZobristHash.hash(of: $0) })
        #expect(rejected.isEmpty == false)
        var cursor = ImprovingPivotCandidateCursor(sequence: fixture.sequence, graph: fixture.graph, rejectCache: rejected)
        #expect(cursor.next() == nil)
        let constructed = cursor.constructedCandidateCount
        #expect(constructed > 0)
        #expect(cursor.next() == nil)
        #expect(cursor.constructedCandidateCount == constructed)
    }

    @Test("Cached fills do not spend the machine's improving probe budget")
    func cachedFillDoesNotSpendBudget() throws {
        var propertyCalls = 0
        var machine = try makeMachine(budget: 1) { _ in
            propertyCalls += 1
            return true
        }
        let candidates = EagerScopeReference.improvingPivotCandidates(sequence: machine.sequence, graph: machine.graph)
        #expect(candidates.count == 2)
        let first = try #require(candidates.first)
        machine.rejectCache.insert(ZobristHash.hash(of: first))
        #expect(machine.hasUnprobedImprovingPivot)
        let accepted = machine.runImprovingPivotPass()
        #expect(accepted == false)
        #expect(propertyCalls == 1)
        #expect(machine.stats.relaxImprovingProbes == 1)
        #expect(machine.stats.reductionProbes == 1)
        #expect(machine.hasUnprobedImprovingPivot == false)
        #expect(machine.output as? UInt64 == 250)
    }

    @Test("Duplicate fills retain the pass-entry cache semantics")
    func duplicateFills() throws {
        let tree = ChoiceTree.pickSite(fingerprint: 42, selected: 1, branches: [leaf(100, range: 0 ... 100), leaf(250, range: 200 ... 300)])
        let sequence = ChoiceSequence(tree)
        let graph = ChoiceGraph.build(from: tree)
        var cursor = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: [])
        let first = cursor.next()
        let recorded = try #require(first)
        let second = cursor.next()
        let farthest = try #require(second)
        #expect(recorded.sequence == farthest.sequence)
        #expect(recorded.probeHash == farthest.probeHash)
        #expect(cursor.next() == nil)
        var cached = ImprovingPivotCandidateCursor(sequence: sequence, graph: graph, rejectCache: [recorded.probeHash])
        #expect(cached.next() == nil)
    }

    @Test("Deadlines stop preparation without constructing candidates; a prepared prefix remains enumerable")
    func preparationDeadline() {
        let fixture = mixedPivots()
        let deadline = CursorDeadline()
        deadline.remainingChecks = 0
        var expired = ImprovingPivotCandidateCursor(sequence: fixture.sequence, graph: fixture.graph, rejectCache: [], deadlineCheck: deadline.isExpired)
        #expect(expired.preparedPivotCount == 0)
        #expect(expired.constructedCandidateCount == 0)
        #expect(expired.next() == nil)
        deadline.remainingChecks = 2
        var interrupted = ImprovingPivotCandidateCursor(sequence: fixture.sequence, graph: fixture.graph, rejectCache: [], deadlineCheck: deadline.isExpired)
        #expect(interrupted.preparedPivotCount == 1)
        #expect(interrupted.constructedCandidateCount == 0)
        #expect(interrupted.next() != nil)
        #expect(interrupted.constructedCandidateCount == 1)
        deadline.remainingChecks = nil
        while interrupted.next() != nil {}
        #expect(interrupted.next() == nil)
    }

    @Test("Enumeration does not consult the scheduler's preparation deadline")
    func generationIsIndependentOfDeadline() {
        let fixture = mixedPivots()
        let deadline = CursorDeadline()
        var cursor = ImprovingPivotCandidateCursor(sequence: fixture.sequence, graph: fixture.graph, rejectCache: [], deadlineCheck: deadline.isExpired)
        deadline.remainingChecks = 0
        #expect(cursor.next() != nil)
        #expect(cursor.constructedCandidateCount == 1)
        #expect(deadline.remainingChecks == 0)
        deadline.remainingChecks = nil
        #expect(cursor.next() != nil)
        #expect(cursor.constructedCandidateCount == 2)
    }

    // MARK: - Helpers

    private func leaf(_ value: UInt64, range: ClosedRange<UInt64>) -> ChoiceTree {
        .choice(ChoiceValue(value, tag: .uint64), .init(validRange: range, isRangeExplicit: true))
    }

    /// Exercises length ties, shorter arms, out-of-order discovery, and an arm with few leaves but too much framing to improve length.
    private func mixedPivots() -> (sequence: ChoiceSequence, graph: ChoiceGraph) {
        let tree = ChoiceTree.group([
            .pickSite(fingerprint: 42, selected: 1, branches: [leaf(2, range: 0 ... 10), leaf(5, range: 0 ... 10)]),
            .pickSite(fingerprint: 43, selected: 1, branches: [leaf(9, range: 0 ... 10), .group([leaf(5, range: 0 ... 10), leaf(6, range: 0 ... 10)], isZip: true)]),
            .pickSite(fingerprint: 44, selected: 1, branches: [leaf(10, range: 0 ... 100), leaf(250, range: 200 ... 300)]),
            .pickSite(fingerprint: 45, selected: 1, branches: [.sequence(elements: [leaf(1, range: 0 ... 10)], metadata: .init(validRange: nil)), leaf(5, range: 0 ... 10)]),
        ])
        return (ChoiceSequence(tree), ChoiceGraph.build(from: tree))
    }

    private func makeMachine(budget: Int, property: @escaping (UInt64) -> Bool) throws -> ReductionMachine {
        let generator = Gen.pick(choices: [
            (1, Gen.choose(in: UInt64(0) ... 100)),
            (1, Gen.choose(in: UInt64(200) ... 300)),
        ])
        let tree = try #require(try Interpreters.reflect(generator, with: UInt64(250)))
        var tuning = SchedulerTuning()
        tuning.relaxImprovingProbeBudget = budget
        return ReductionMachine(gen: generator, initialTree: tree, initialOutput: UInt64(250), config: .init(maxStalls: 2, enabledEncoders: [.branchPivot], tuning: tuning), collectStats: true, property: property)
    }
}

/// Expires on a deterministic check boundary, allowing tests to interrupt preparation separately from generation.
private final class CursorDeadline {
    var remainingChecks: Int?

    func isExpired() -> Bool {
        guard let remainingChecks else {
            return false
        }
        guard remainingChecks > 0 else {
            return true
        }
        self.remainingChecks = remainingChecks - 1
        return false
    }
}
