import Testing
@testable import ExhaustCore

@Suite("Scoped reduction interpreter")
struct ScopedReductionInterpreterTests {
    @Test("A search inside a propose branch continues with its outcome, as a top-level search does", arguments: [false, true])
    func branchSearchContinues(insidePropose: Bool) throws {
        let fixture = try InterpreterFixture()
        let candidate = try fixture.candidate(value: 3)
        let configuration = ScopedSearchConfiguration(acceptance: .continue, requiresExactDecoder: false, reportedMutation: nil)
        var continuationOutcome: ScopedSearchOutcome?
        let sequenced: ScopedReducer = .search(.singleCandidate(ScopedSingleCandidateSearch()), configuration: configuration) { outcome in
            continuationOutcome = outcome
            return .search(
                .singleCandidate(ScopedSingleCandidateSearch(candidate: candidate, mutation: .leafValues([]))),
                configuration: configuration
            )
        }
        let reducer: ScopedReducer = switch insidePropose {
            case false:
                sequenced
            case true:
                .propose(
                    [ScopedBranch(proposal: LiftProposal(prefix: fixture.sequence, mutation: .leafValues([])), cost: 0)],
                    configuration: ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: nil, totalProbeCap: 0)
                ) { _ in
                    sequenced
                }
        }

        let report = fixture.run(reducer)

        #expect(report.counts.emitted == 1)
        let outcome = try #require(continuationOutcome)
        #expect(outcome.stopReason == .exhausted)
        #expect(outcome.anyAccepted == false)
        #expect(outcome.counts.emitted == 0)
    }
}

// MARK: - Fixture

/// A single bounded integer, whose property always fails so every decoded candidate is admissible.
private struct InterpreterFixture {
    let generator = Gen.choose(in: UInt64(0) ... 100)
    let tree: ChoiceTree
    let sequence: ChoiceSequence

    init() throws {
        tree = try #require(try Interpreters.reflect(generator, with: 5))
        sequence = ChoiceSequence(tree)
    }

    func candidate(value: UInt64) throws -> ChoiceSequence {
        try ChoiceSequence(#require(try Interpreters.reflect(generator, with: value)))
    }

    func run(_ reducer: ScopedReducer) -> ScopedPassReport {
        ScopedReductionInterpreter.run(
            reducer,
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: UInt64(5))
                ),
                graph: ChoiceGraph.build(from: tree),
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator.erase(),
                    property: { _ in false },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoderName: .valueSearch
            )
        ).report
    }
}
