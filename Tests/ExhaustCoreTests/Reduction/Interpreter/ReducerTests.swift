import Testing
@testable import ExhaustCore

@Suite("Reduction interpreter")
struct ReducerTests {
    @Test("A search inside a propose attempt continues with its outcome, as a top-level search does", arguments: [false, true])
    func attemptSearchContinues(insidePropose: Bool) throws {
        let fixture = try InterpreterFixture()
        let candidate = try fixture.candidate(value: 3)
        let configuration = SearchConfiguration(graphUpdate: .applyMutation, requiresExactDecoder: false)
        var continuationOutcome: SearchOutcome?
        let sequenced: Reduction = .search(SingleCandidateSearch(), configuration: configuration) { outcome in
            continuationOutcome = outcome
            return .search(
                SingleCandidateSearch(candidate: candidate, mutation: .leafValues([])),
                configuration: configuration
            )
        }
        let reduction: Reduction = switch insidePropose {
            case false:
                sequenced
            case true:
                .propose(
                    { RepeatedProposals(prefix: fixture.sequence, count: 1) },
                    configuration: ChoiceConfiguration(probesPerAttemptTurn: nil, constructedAttemptLimit: nil, totalProbeCap: 0),
                    then: { _ in
                        sequenced
                    }
                )
        }

        let report = fixture.run(reduction)

        #expect(report.counts.emitted == 1)
        let outcome = try #require(continuationOutcome)
        #expect(outcome.anyAccepted == false)
        #expect(outcome.counts.emitted == 0)
    }

    @Test("A level whose attempts fail construction stops building at the deadline")
    func failedBuildsStopAtDeadline() throws {
        let fixture = try InterpreterFixture()
        var attemptsBuilt = 0
        let reduction: Reduction = .propose(
            { RepeatedProposals(prefix: fixture.sequence, count: 4) },
            configuration: ChoiceConfiguration(probesPerAttemptTurn: nil, constructedAttemptLimit: nil, totalProbeCap: 0),
            then: { proposal in
                attemptsBuilt += 1
                return .lift(proposal, fallbackTree: fixture.tree) { _ in
                    .fail(.bindNotFound)
                }
            }
        )

        // Expires once the second attempt has started building, so only the first attempt's lift runs.
        let report = fixture.run(reduction, deadline: ReductionDeadline(start: 0, budget: 2, clock: { UInt64(attemptsBuilt) }))

        #expect(attemptsBuilt == 2)
        #expect(report.liftAttempts == 1)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 1, outcome: .failed(.bindNotFound))] == 1)
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

    func run(_ reduction: Reduction, deadline: ReductionDeadline = .none) -> ReductionPassReport {
        Reducer.reduce(
            reduction,
            context: Reducer.Context(
                incumbent: Counterexample(
                    sequence: sequence,
                    tree: tree,
                    output: UInt64(5)
                ),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: ChoiceGraph.build(from: tree),
                rejectCache: [],
                decoder: ReductionDecoder(
                    generator: generator.erase(),
                    property: { _ in false },
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: ValueSearchEncoder.self,
                deadline: deadline
            )
        ).report
    }
}

/// Proposes the same prefix `count` times.
private struct RepeatedProposals: ProposalCursor {
    let prefix: ChoiceSequence
    let count: Int
    var emitted = 0

    mutating func next(into buffer: inout ChoiceSequence) -> LiftProposal? {
        guard emitted < count else {
            return nil
        }
        emitted += 1
        buffer = prefix
        return LiftProposal(prefix: .init(buffer), mutation: .leafValues([]))
    }
}
