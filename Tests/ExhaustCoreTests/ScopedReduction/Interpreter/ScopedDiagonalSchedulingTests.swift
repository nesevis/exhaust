import Testing
@testable import ExhaustCore

@Suite("Scoped diagonal scheduling")
struct ScopedDiagonalSchedulingTests {
    @Test("Branch positions and candidate counts form diagonals, and later branches are built only when selected")
    func diagonalOrderAndLazyBuilds() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 3, recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "A1", "B0", "A2", "B1", "C0", "B2", "C1", "C2"])
        #expect(Array(recorder.events.prefix(13)) == [
            "setup", "proposal 0", "build 0", "A0", "A1", "proposal 1", "build 1", "B0", "A2", "B1", "proposal 2", "build 2", "C0",
        ])
        #expect(report.counts.emitted == 9)
        #expect(report.constructedSearches == 3)
        #expect(recorder.finished.values.allSatisfy { $0 == ["initial"] })
        #expect(recorder.finished.count == 3)
    }

    @Test("A failed build returns to priority selection before a more expensive branch is built")
    func failedBuildReselects() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 3, recorder: recorder) { index in
            switch index {
                case 0:
                    fixture.search("A", recorder: recorder)
                case 1:
                    .fail(.bindNotFound)
                default:
                    fixture.search("C", values: [10], recorder: recorder)
            }
        }

        let report = fixture.run(reducer)

        #expect(recorder.events == ["setup", "proposal 0", "build 0", "A0", "A1", "proposal 1", "build 1", "A2", "proposal 2", "build 2", "C0"])
        #expect(report.constructedSearches == 2)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 1, outcome: .failed(.bindNotFound))] == 1)
    }

    @Test("Sequential searches keep their branch's accumulated grade")
    func continuationKeepsProgress() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 2, recorder: recorder) { index in
            guard index == 0 else {
                return fixture.search("B", recorder: recorder)
            }
            return .search(
                RecordingScheduleSearch(name: "first", values: [10, 11], base: fixture.sequence, recorder: recorder),
                configuration: .standard
            ) { outcome in
                #expect(outcome.counts.emitted == 2)
                return fixture.search("second", values: [12, 13], recorder: recorder)
            }
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["first0", "first1", "B0", "second0", "B1", "second1", "B2"])
    }

    @Test("Nested pools schedule independently without adding their grades to the parent")
    func nestedPoolsStayLocal() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 2, recorder: recorder) { index in
            guard index == 0 else {
                return fixture.search("B", values: [20], recorder: recorder)
            }
            // Two failed builds start the child's only search at grade 2, which would put B ahead of X1 if it reached the parent.
            return fixture.pool(count: 3, recorder: recorder) { childIndex in
                guard childIndex == 2 else {
                    return .fail(.bindNotFound)
                }
                return fixture.search("X", values: [10, 11], recorder: recorder)
            }
        }

        let report = fixture.run(reducer)

        #expect(recorder.emissions == ["X0", "X1", "B0"])
        #expect(report.constructedSearches == 2)
        #expect(report.nestedConstructedSearches == 1)
    }

    @Test("The probe cap stops before opening another branch and finishes the pending search once")
    func probeCapAndFinishing() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: nil, totalProbeCap: 2)
        let reducer = fixture.pool(count: 2, configuration: configuration, recorder: recorder) { index in
            fixture.search(["A", "B"][index], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "A1"])
        #expect(recorder.builds == [0])
        #expect(recorder.finished == ["A": ["passed"]])
        #expect(report.counts.emitted == 2)
        #expect(report.constructedSearches == 1)
    }

    @Test("Failed builds do not consume the search budget, while an empty search does")
    func searchBudgetCountsEmptySearches() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: 1, totalProbeCap: 0)
        let reducer = fixture.pool(count: 3, configuration: configuration, recorder: recorder) { index in
            guard index > 0 else {
                return .fail(.bindNotFound)
            }
            return fixture.search(["unused", "empty", "C"][index], values: index == 1 ? [] : [10], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.builds == [0, 1])
        #expect(recorder.emissions.isEmpty)
        #expect(recorder.finished == ["empty": ["initial"]])
        #expect(report.constructedSearches == 1)
    }

    @Test("Chain build limits count failed builds before another branch can be opened")
    func chainBuildLimits() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            chainLimits: ScopedChainLimits(maxBuildsPerStart: 2, poolCapacity: 2)
        )
        let reducer = fixture.pool(count: 3, configuration: configuration, recorder: recorder) { _ in
            .fail(.bindNotFound)
        }

        let report = fixture.run(reducer)

        #expect(recorder.builds == [0, 1])
        #expect(report.constructedSearches == 0)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 1, outcome: .failed(.bindNotFound))] == 2)
    }

    @Test("Each resumed search receives its own feedback, with uniform feedback still withheld", arguments: [false, true])
    func feedbackStaysWithSearch(uniform: Bool) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            deliversUniformFeedback: uniform
        )
        let reducer = fixture.pool(count: 2, configuration: configuration, recorder: recorder) { index in
            fixture.search(["A", "B"][index], values: index == 0 ? [10, 10] : [20, 20], recorder: recorder)
        }

        _ = fixture.run(reducer)

        let feedback = uniform ? ["initial", "uniform", "uniform"] : ["initial", "passed", "cached"]
        #expect(recorder.feedback["A"] == feedback)
        #expect(recorder.feedback["B"] == feedback)
    }

    @Test("An acceptance that stops the pass leaves later branches unbuilt")
    func acceptanceStopsPool() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 2, recorder: recorder) { index in
            fixture.search(
                ["A", "B"][index],
                values: [0],
                recorder: recorder,
                configuration: ScopedSearchConfiguration(acceptance: .stop, requiresExactDecoder: false, reportedMutation: nil)
            )
        }

        let report = fixture.run(reducer, property: { _ in false })

        #expect(recorder.emissions == ["A0"])
        #expect(recorder.builds == [0])
        #expect(recorder.finished == ["A": ["accepted"]])
        #expect(report.counts.accepted == 1)
        #expect(report.anyRequiresRebuild)
    }

    @Test("A deadline between candidates finishes suspended searches without opening another branch")
    func deadlineStopsPool() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 2, recorder: recorder) { index in
            fixture.search(["A", "B"][index], recorder: recorder)
        }
        let deadline = ScopedDeadline(start: 0, budget: 1, clock: { recorder.propertyCalls == 0 ? 0 : 1 })

        let report = fixture.run(reducer, deadline: deadline, property: { _ in
            recorder.propertyCalls += 1
            return true
        })

        #expect(recorder.emissions == ["A0"])
        #expect(recorder.builds == [0])
        #expect(recorder.finished == ["A": ["passed"]])
        #expect(report.counts.emitted == 1)
    }

    @Test("Bound value reduction lifts and searches dependent ranges under the default diagonal policy")
    func boundValueReduction() throws {
        let generator = Gen.choose(in: UInt64(0) ... 20)._bound(
            forward: { controller in
                Gen.zip(Gen.just(controller), Gen.choose(in: UInt64(0) ... controller))
            },
            backward: { pair in pair.0 }
        )
        let start: (UInt64, UInt64) = (20, 20)
        let tree = try #require(try Interpreters.reflect(generator, with: start))

        let result = ScopedReductionRunner.reduce(
            generator: generator,
            tree: tree,
            output: start,
            configuration: ScopedReductionRunner.Configuration(maxStalls: 2, enabledEncoders: [.boundValueSearch]),
            collectStats: true,
            property: { pair in pair.0 + pair.1 < 10 }
        )

        let reduced = try #require(result.outcome.counterexample).1
        #expect(reduced.0 < start.0)
        #expect(reduced.1 <= reduced.0)
        #expect(reduced.0 + reduced.1 >= 10)
        #expect(result.stats.liftAttemptsByEncoder[.boundValueSearch, default: 0] > 0)
    }

    @Test("The turn-based policy builds every branch before resuming any, with fixed turns")
    func turnBasedComparison() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: 2, searchBudget: nil, totalProbeCap: 0, scheduling: .turnBased)
        let reducer = fixture.pool(count: 3, configuration: configuration, recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "A1", "B0", "B1", "C0", "C1", "A2", "B2", "C2"])
    }
}

@Suite("Scoped lazy proposals")
struct ScopedLazyProposalTests {
    @Test("The proposal factory runs once, when the first branch is selected, under either policy", arguments: [ScopedChoiceScheduling.diagonal, .turnBased])
    func factoryRunsOnceAtFirstSelection(scheduling: ScopedChoiceScheduling) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: 2, searchBudget: nil, totalProbeCap: 0, scheduling: scheduling)
        let reducer = fixture.pool(count: 3, configuration: configuration, recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], recorder: recorder)
        }
        #expect(recorder.factoryCalls == 0)
        #expect(recorder.proposals.isEmpty)

        let report = fixture.run(reducer)

        let expectedEmissions = switch scheduling {
            case .diagonal:
                ["A0", "A1", "B0", "A2", "B1", "C0", "B2", "C1", "C2"]
            case .turnBased:
                ["A0", "A1", "B0", "B1", "C0", "C1", "A2", "B2", "C2"]
        }
        #expect(recorder.emissions == expectedEmissions)
        #expect(recorder.builds == [0, 1, 2])
        #expect(recorder.factoryCalls == 1)
        #expect(recorder.proposals == [0, 1, 2])
        #expect(report.counts.emitted == 9)
    }

    @Test("A probe cap constructs only the reached prefix, without looking ahead", arguments: [ScopedChoiceScheduling.diagonal, .turnBased])
    func probeCapDoesNotConstructLaterProposals(scheduling: ScopedChoiceScheduling) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: 2, searchBudget: nil, totalProbeCap: 2, scheduling: scheduling)
        let reducer = fixture.pool(count: 1_000_000, configuration: configuration, recorder: recorder) { _ in
            fixture.search("A", recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.events == ["setup", "proposal 0", "build 0", "A0", "A1"])
        #expect(recorder.proposalRequests == 1)
        #expect(recorder.finished == ["A": ["passed"]])
    }

    @Test("Zero search or build allowances do not initialize the cursor", arguments: [0, 1, 2])
    func zeroBudgetsAvoidSetup(limit: Int) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: limit == 0 ? 0 : nil,
            totalProbeCap: 0,
            chainLimits: limit == 0 ? nil : ScopedChainLimits(maxBuildsPerStart: limit == 1 ? 0 : 1, poolCapacity: limit == 2 ? 0 : 1)
        )
        let reducer = fixture.pool(count: 3, configuration: configuration, recorder: recorder) { _ in
            fixture.search("unused", recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.factoryCalls == 0)
        #expect(recorder.proposalRequests == 0)
        #expect(report.constructedSearches == 0)
    }

    @Test("A failed build and an empty search consume only their own proposals", arguments: [ScopedChoiceScheduling.diagonal, .turnBased])
    func searchBudgetStopsProposalConstruction(scheduling: ScopedChoiceScheduling) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: 1, totalProbeCap: 0, scheduling: scheduling)
        let reducer = fixture.pool(count: 1_000_000, configuration: configuration, recorder: recorder) { index in
            guard index > 0 else {
                return .fail(.bindNotFound)
            }
            return fixture.search("empty", values: [], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.proposals == [0, 1])
        #expect(recorder.proposalRequests == 2)
        #expect(report.constructedSearches == 1)
        #expect(recorder.finished == ["empty": ["initial"]])
    }

    @Test("The chain build cap is checked before constructing another prefix", arguments: [ScopedChoiceScheduling.diagonal, .turnBased])
    func buildBudgetStopsProposalConstruction(scheduling: ScopedChoiceScheduling) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            chainLimits: ScopedChainLimits(maxBuildsPerStart: 2, poolCapacity: 2),
            scheduling: scheduling
        )
        let reducer = fixture.pool(count: 1_000_000, configuration: configuration, recorder: recorder) { _ in
            .fail(.bindNotFound)
        }

        let report = fixture.run(reducer)

        #expect(recorder.proposals == [0, 1])
        #expect(recorder.proposalRequests == 2)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 1, outcome: .failed(.bindNotFound))] == 2)
    }

    @Test("A child cursor's exhaustion spends no shared build allowance", arguments: [ScopedChoiceScheduling.diagonal, .turnBased])
    func exhaustionDoesNotSpendBuilds(scheduling: ScopedChoiceScheduling) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(
            probesPerSearchTurn: nil,
            searchBudget: nil,
            totalProbeCap: 0,
            chainLimits: ScopedChainLimits(maxBuildsPerStart: 2, poolCapacity: 3),
            scheduling: scheduling
        )
        let reducer = fixture.pool(count: 2, configuration: configuration, recorder: recorder) { index in
            guard index > 0 else {
                return fixture.pool(count: 1, configuration: configuration, recorder: recorder) { _ in
                    .fail(.bindNotFound)
                }
            }
            return fixture.search("B", values: [10], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.builds == [0, 0, 1])
        #expect(recorder.emissions == ["B0"])
        #expect(report.constructedSearches == 2)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 2, outcome: .failed(.bindNotFound))] == 1)
    }

    @Test("Acceptance leaves later prefixes unconstructed")
    func acceptanceStopsProposalConstruction() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 1_000_000, recorder: recorder) { _ in
            fixture.search(
                "A",
                values: [0],
                recorder: recorder,
                configuration: ScopedSearchConfiguration(acceptance: .stop, requiresExactDecoder: false, reportedMutation: nil)
            )
        }

        let report = fixture.run(reducer, property: { _ in false })

        #expect(recorder.proposals == [0])
        #expect(recorder.proposalRequests == 1)
        #expect(report.counts.accepted == 1)
        #expect(recorder.finished == ["A": ["accepted"]])
    }

    @Test("Deadlines prevent cursor setup or subsequent prefix construction", arguments: [false, true])
    func deadlineStopsProposalConstruction(startsExpired: Bool) throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 1_000_000, recorder: recorder) { _ in
            fixture.search("A", recorder: recorder)
        }
        let deadline = ScopedDeadline(start: 0, budget: 1, clock: { startsExpired || recorder.propertyCalls > 0 ? 1 : 0 })

        _ = fixture.run(reducer, deadline: deadline, property: { _ in
            recorder.propertyCalls += 1
            return true
        })

        #expect(recorder.factoryCalls == (startsExpired ? 0 : 1))
        #expect(recorder.proposals == (startsExpired ? [] : [0]))
        #expect(recorder.proposalRequests == (startsExpired ? 0 : 1))
    }

    @Test("Interpreting the same reducer again starts an independent proposal cursor")
    func repeatedInterpretationStartsFresh() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(count: 2, recorder: recorder) { index in
            fixture.search(["A", "B"][index], values: [10], recorder: recorder)
        }

        let first = fixture.run(reducer)
        let second = fixture.run(reducer)

        #expect(recorder.factoryCalls == 2)
        #expect(recorder.proposals == [0, 1, 0, 1])
        #expect(recorder.emissions == ["A0", "B0", "A0", "B0"])
        #expect(first.counts == second.counts)
    }
}

// MARK: - Fixtures

/// Records actual branch construction, candidate emission, feedback, and finalization across interleaved searches.
private final class SchedulingRecorder {
    var factoryCalls = 0
    var proposalRequests = 0
    var proposals: [Int] = []
    var builds: [Int] = []
    var emissions: [String] = []
    var events: [String] = []
    var feedback: [String: [String]] = [:]
    var finished: [String: [String]] = [:]
    var propertyCalls = 0

    static func describe(_ feedback: ScopedSearchFeedback) -> String {
        switch feedback {
            case .initial:
                "initial"
            case .accepted:
                "accepted"
            case .rejected(.cached):
                "cached"
            case .rejected(.undifferentiated):
                "uniform"
            case .rejected(.propertyPassed):
                "passed"
            case .rejected:
                "rejected"
        }
    }
}

/// Exposes cursor setup and prefix construction separately from branch builds, including requests that discover exhaustion.
private struct RecordingProposalCursor: ScopedProposalCursor {
    let count: Int
    let base: ChoiceSequence
    let recorder: SchedulingRecorder
    var position = 0

    mutating func next(into buffer: inout ChoiceSequence) -> LiftProposal? {
        recorder.proposalRequests += 1
        guard position < count else {
            return nil
        }
        recorder.proposals.append(position)
        recorder.events.append("proposal \(position)")
        buffer = base
        buffer[0] = buffer[0].withBitPattern(UInt64(position))
        position += 1
        return LiftProposal(prefix: buffer, mutation: .leafValues([]))
    }
}

/// Emits known candidates so feedback and scheduling can be checked independently of a numeric search algorithm.
private struct RecordingScheduleSearch: ScopedSearch {
    let name: String
    let values: [UInt64]
    let base: ChoiceSequence
    let recorder: SchedulingRecorder
    var nextIndex = 0

    mutating func next(_ feedback: ScopedSearchFeedback, into buffer: inout ChoiceSequence) -> ScopedCandidate? {
        recorder.feedback[name, default: []].append(SchedulingRecorder.describe(feedback))
        guard nextIndex < values.count else {
            return nil
        }
        let label = "\(name)\(nextIndex)"
        recorder.emissions.append(label)
        recorder.events.append(label)
        buffer = base
        buffer[0] = buffer[0].withBitPattern(values[nextIndex])
        nextIndex += 1
        return .written(mutation: .leafValues([]), admission: .standard)
    }

    consuming func finish(pending: ScopedSearchFeedback) -> ScopedSearchReport {
        recorder.finished[name, default: []].append(SchedulingRecorder.describe(pending))
        return ScopedSearchReport()
    }
}

/// Runs compositions over one integer, normally rejecting every candidate so the complete schedule is observable.
private struct SchedulingFixture {
    let generator = Gen.choose(in: UInt64(0) ... 100)
    let tree: ChoiceTree
    let sequence: ChoiceSequence

    init() throws {
        tree = try #require(try Interpreters.reflect(generator, with: 5))
        sequence = ChoiceSequence(tree)
    }

    func pool(
        count: Int,
        configuration: ScopedChoiceConfiguration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: nil, totalProbeCap: 0),
        recorder: SchedulingRecorder,
        build: @escaping (Int) -> ScopedReducer
    ) -> ScopedReducer {
        .propose(
            {
                recorder.factoryCalls += 1
                recorder.events.append("setup")
                return RecordingProposalCursor(count: count, base: sequence, recorder: recorder)
            },
            configuration: configuration,
            then: { proposal in
                guard let value = proposal.prefix[0].value else {
                    preconditionFailure("Every fixture prefix starts with a value entry")
                }
                let index = Int(value.choice.bitPattern64)
                recorder.builds.append(index)
                recorder.events.append("build \(index)")
                return build(index)
            }
        )
    }

    func search(
        _ name: String,
        values: [UInt64] = [10, 11, 12],
        recorder: SchedulingRecorder,
        configuration: ScopedSearchConfiguration = .standard
    ) -> ScopedReducer {
        .search(RecordingScheduleSearch(name: name, values: values, base: sequence, recorder: recorder), configuration: configuration)
    }

    func run(
        _ reducer: ScopedReducer,
        deadline: ScopedDeadline = .none,
        property: @escaping (Any) -> Bool = { _ in true }
    ) -> ScopedPassReport {
        ScopedReductionInterpreter.reduce(
            reducer,
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(sequence: sequence, tree: tree, output: UInt64(5)),
                incumbentHash: ZobristHash.hash(of: sequence),
                graph: ChoiceGraph.build(from: tree),
                rejectCache: [],
                decoder: ScopedDecoder(generator: generator.erase(), property: property, probeWrapper: nil, hasBind: false),
                encoder: ScopedValueSearchEncoder.self,
                deadline: deadline
            )
        ).report
    }
}
