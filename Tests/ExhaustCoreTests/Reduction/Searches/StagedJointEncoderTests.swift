import Testing
@testable import ExhaustCore

@Suite("Staged joint encoder")
struct StagedJointEncoderTests {
    @Test("Coordinated search reaches the primitive ratio after cheaper stages stall", arguments: [[2, 4], [2, 4, 6], [2, 4, 6, 10]])
    func coordinatedSearchFindsPrimitiveRatio(values: [Int]) throws {
        let primitive = values.map { $0 / 2 }
        let fixture = try StagedJointFixture(values: values) { candidate in
            candidate.indices.contains { candidate[$0] != primitive[$0] * candidate[0] }
        }

        let result = fixture.run()

        #expect(result.output == primitive)
        #expect(result.report.anyAccepted)
        #expect(result.report.searchCounts.map(\.stagedJointArity) == Array(2 ... values.count))
        #expect(result.report.searchCounts.dropLast().allSatisfy { $0.counts.accepted == 0 })
        #expect(result.report.searchCounts.last?.counts.accepted == 1)
    }

    @Test("A rejected sign flip continues into pair search within the shared budget")
    func signFlipFallsBackToPairs() throws {
        let values = [-2, -4]
        let fixture = try StagedJointFixture(values: values, range: -100 ... 100) { candidate in
            candidate != values && candidate != [0, 1]
        }
        let signFlipOnly = fixture.run(probeBudget: 1)
        #expect(signFlipOnly.output == values)
        #expect(signFlipOnly.report.counts.emitted == 1)
        #expect(signFlipOnly.report.counts.propertyInvocations == 1)
        #expect(signFlipOnly.report.searchCounts.map(\.stagedJointArity) == [2])

        let complete = fixture.run()
        #expect(complete.output == [0, 1])
        #expect(complete.report.searchCounts.map(\.stagedJointArity) == [2])
        #expect(complete.report.searchCounts.last?.counts.accepted == 1)

        let disabled = fixture.run(probeBudget: 0)
        #expect(disabled.output == values)
        #expect(disabled.report.counts.emitted == 0)
    }

    @Test("An accepted group sign flip ends the checkpoint", arguments: [2, 3, 4])
    func signFlipAcceptance(arity: Int) throws {
        let values = Array([-2, 4, -6, 8].prefix(arity))
        let positive = values.map { -$0 }
        let fixture = try StagedJointFixture(values: values, range: -100 ... 100) { candidate in
            candidate != values && candidate != positive
        }
        let result = fixture.run()
        #expect(result.output == positive)
        #expect(result.report.counts.accepted == 1)
        #expect(result.report.searchCounts.map(\.stagedJointArity) == Array(2 ... arity))
        #expect(result.report.searchCounts.last?.counts.emitted == 1)
    }

    @Test("A positive group emits no sign flip, because a negative earliest leaf cannot precede the checkpoint")
    func positiveGroupEmitsNoSignFlip() throws {
        let values = [2, 4]
        let flipped = values.map { (-$0).bitPattern64 }
        let fixture = try StagedJointFixture(values: values, range: -100 ... 100) { _ in false }
        #expect(fixture.scope.pairs.isEmpty == false)

        var search = StagedJointSearch(pairs: fixture.scope.pairs, base: fixture.sequence, probeBudget: 10000)
        var buffer = fixture.sequence
        var feedback = SearchFeedback.initial
        var emitted = 0
        while let candidate = search.next(feedback, into: &buffer) {
            emitted += 1
            if case let .lazy(probe) = candidate.contents {
                #expect(probe.map { $0.replacement.value!.choice.bitPattern64 } != flipped)
            }
            feedback = .rejected(.propertyPassed)
        }
        #expect(emitted > 0)
    }

    @Test("A deadline that expires between stages starts no further stage", arguments: [1, 2])
    func deadlineBetweenStages(completedStages: Int) throws {
        // Only an exact linear quadruple fails, so the pair and three-way stages exhaust and the search escalates to four leaves.
        let fixture = try StagedJointFixture(values: [2, 4, 6, 10]) { values in
            values[1] != 2 * values[0] || values[2] != 3 * values[0] || values[3] != 5 * values[0]
        }
        let complete = fixture.run()
        #expect(complete.report.searchCounts.map(\.stagedJointArity) == [2, 3, 4])
        let completed = complete.report.searchCounts.prefix(completedStages)
        let emissions = completed.reduce(0) { $0 + $1.counts.emitted }
        let checksAtLastProbe = try #require(complete.checksAtTermination[emissions])

        // The last completed stage's exhaustion check passes; the next check precedes the following stage.
        let interrupted = fixture.run(deadlineAfterChecks: checksAtLastProbe + 1)

        #expect(interrupted.report.searchCounts == Array(completed))
        #expect(interrupted.report.counts.emitted == emissions)
    }

    @Test("A stalled pair flips mixed signs while an unrelated positive value stays unchanged", arguments: [true, false])
    func reducerIntegration(acceptsSignFlip: Bool) throws {
        let generator = Gen.arrayOf(Gen.choose(in: -100 ... 100), within: 3 ... 3)
        let values = [-3, 5, 17]
        let signFlipped = [3, -5, 17]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var tuning = ReductionTuning()
        tuning.stagedJointProbeBudget = 1
        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: values,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .stagedJointSearch], tuning: tuning),
            property: { candidate in candidate != values && (acceptsSignFlip == false || candidate != signFlipped) }
        )
        #expect(result.outcome.counterexample?.1 == (acceptsSignFlip ? signFlipped : values))
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.accepted == (acceptsSignFlip ? 1 : 0))
    }

    @Test("Replay rejects a sign flip that violates a generator filter")
    func generatorFilter() throws {
        let generator = Gen.filter(
            Gen.arrayOf(Gen.choose(in: -100 ... 100), within: 2 ... 2),
            type: .rejectionSampling,
            predicate: { $0.allSatisfy { $0 < 0 } },
            sourceLocation: FilterSourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: #column)
        )
        let values = [-3, -5]
        let tree = try #require(try Interpreters.reflect(generator, with: values))
        var tuning = ReductionTuning()
        tuning.stagedJointProbeBudget = 1
        let result = Interpreters.choiceGraphReduceCollectingStats(
            gen: generator,
            tree: tree,
            output: values,
            config: .init(maxStalls: 2, enabledEncoders: [.valueSearch, .stagedJointSearch], tuning: tuning),
            property: { $0 != values }
        )
        #expect(result.outcome.counterexample?.1 == values)
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.propertyInvocations == 0)
        #expect(result.stats.encoderCounts[.stagedJointSearch]?.accepted == 0)
    }

    @Test("A pair whose signs cannot be flipped does not suppress another pair and sampled sign flips are not repeated")
    func selectedPairsAndDeduplication() throws {
        let values = [Int8.min, -1, 1].map { ChoiceValue($0, tag: .int8) }
        let members = leaves(values)
        let pairs = [
            NumericPair(source: members[0], sink: members[1]),
            NumericPair(source: members[1], sink: members[2]),
        ]
        let base = ChoiceSequence(values.map {
            ChoiceSequenceValue.value(.init(choice: $0, validRange: $0.tag.bitPatternRange))
        })
        var search = StagedJointSearch(pairs: pairs, base: base, probeBudget: 10000)
        var buffer = base
        let first = try #require(search.next(.initial, into: &buffer))
        guard case let .lazy(signFlip) = first.contents else {
            Issue.record("Expected a lazy sign flip")
            return
        }
        #expect(signFlip.map(\.position) == [1, 2])
        #expect(signFlip.map { $0.replacement.value!.choice.bitPattern64 } == [Int8(1).bitPattern64, Int8(-1).bitPattern64])
        while let candidate = search.next(.rejected(.propertyPassed), into: &buffer) {
            guard case let .lazy(probe) = candidate.contents else {
                Issue.record("Expected lazy joint proposals")
                return
            }
            #expect(probe != signFlip)
        }
    }

    private func leaves(_ values: [ChoiceValue], range: ClosedRange<UInt64>? = nil) -> [ReductionLeaf] {
        values.enumerated().map { index, value in
            ReductionLeaf(nodeID: index, position: index, path: [], choice: value, range: range ?? value.tag.bitPatternRange, bindFingerprints: [], mayReshapeOnAcceptance: false)
        }
    }
}

// MARK: - Fixture

/// Values reflected through a zip of broad integer generators, with every leaf marked converged so the checkpoint is stalled.
private struct StagedJointFixture {
    struct Run {
        let report: ReductionPassReport
        let output: [Int]
        /// Deadline checks made by the time each probe ID terminated.
        let checksAtTermination: [Int: Int]
    }

    let values: [Int]
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let scope: StagedJointEncoder.Scope
    let property: (Any) -> Bool
    static let tuning = ReductionTuning()

    init(values: [Int], range: ClosedRange<Int> = 1 ... 1_000_000, passes: @escaping ([Int]) -> Bool) throws {
        let typed = Gen.eachOf(Array(repeating: Gen.choose(in: range), count: values.count))
        let reflected = try #require(try Interpreters.reflect(typed, with: values))
        var built = ChoiceGraph.build(from: reflected)
        built.markLeavesConverged()
        self.values = values
        generator = typed.erase()
        tree = reflected
        graph = built
        sequence = ChoiceSequence(reflected)
        property = { output in passes(output as! [Int]) }
        scope = StagedJointEncoder.Scope(
            pairs: StagedJointQuery.pairs(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning),
            signFlipProposals: StagedJointQuery.signFlipProposals(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning),
            candidatePool: StagedJointQuery.candidatePool(graph: built, isFruitlessBind: { _ in false }, tuning: Self.tuning)
        )
    }

    /// - Parameter deadlineAfterChecks: Expires the deadline once this many checks have passed; nil never expires.
    func run(deadlineAfterChecks: Int? = nil, probeBudget: Int? = nil) -> Run {
        var tuning = Self.tuning
        if let probeBudget {
            tuning.stagedJointProbeBudget = probeBudget
        }
        let checks = CheckCounter()
        let input = EncoderInput(baseSequence: sequence, tree: tree, graph: graph, warmStartRecords: [:], tuning: tuning)
        let result = Reducer.reduce(
            StagedJointEncoder.reduce(scope, input: input),
            context: Reducer.Context(
                incumbent: Counterexample(
                    sequence: sequence,
                    tree: tree,
                    output: values
                ),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: graph,
                rejectCache: ProbeCache(),
                decoder: ReductionDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoder: StagedJointEncoder.self,
                // Every check reads the clock once, so the clock counts checks. Without a limit the budget is never reached, but each check still reads it.
                deadline: ReductionDeadline(start: 0, budget: deadlineAfterChecks.map { UInt64($0) + 1 } ?? .max) {
                    checks.count += 1
                    return UInt64(checks.count)
                },
                observer: { observation in
                    if case let .terminated(probeID, _, _) = observation {
                        checks.atTermination[probeID] = checks.count
                    }
                }
            )
        )
        return Run(report: result.report, output: result.incumbent.output as! [Int], checksAtTermination: checks.atTermination)
    }
}

/// Counts deadline checks across an interpreter run.
private final class CheckCounter {
    var count = 0
    var atTermination: [Int: Int] = [:]
}
