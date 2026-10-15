import Testing
@testable import ExhaustCore

@Suite("Scoped diagonal scheduling")
struct ScopedDiagonalSchedulingTests {
    @Test("Costs and candidate counts form diagonals, and later branches are built only when selected")
    func diagonalOrderAndLazyBuilds() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [0, 1, 2], recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], recorder: recorder)
        }

        let report = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "A1", "B0", "A2", "B1", "C0", "B2", "C1", "C2"])
        #expect(Array(recorder.events.prefix(9)) == ["build 0", "A0", "A1", "build 1", "B0", "A2", "B1", "build 2", "C0"])
        #expect(report.counts.emitted == 9)
        #expect(report.constructedSearches == 3)
        #expect(recorder.finished.values.allSatisfy { $0 == ["initial"] })
        #expect(recorder.finished.count == 3)
    }

    @Test("Branch cost takes precedence over array position")
    func unorderedCosts() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [2, 0, 1], recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], values: [10], recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["B0", "C0", "A0"])
        #expect(recorder.builds == [1, 2, 0])
    }

    @Test("Equal grades keep original branch order, including after each branch resumes")
    func equalCosts() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [0, 0, 0], recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], values: [10, 11], recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "B0", "C0", "A1", "B1", "C1"])
    }

    @Test("Branch costs at UInt.max still advance without overflowing")
    func largeCosts() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [.max, .max], recorder: recorder) { index in
            fixture.search(["A", "B"][index], values: [10, 11], recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "B0", "A1", "B1"])
    }

    @Test("A failed build returns to priority selection before a more expensive branch is built")
    func failedBuildReselects() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [0, 1, 100], recorder: recorder) { index in
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

        #expect(recorder.events == ["build 0", "A0", "A1", "build 1", "A2", "build 2", "C0"])
        #expect(report.constructedSearches == 2)
        #expect(report.buildOutcomes[CompositionBuildRecord(depth: 1, outcome: .failed(.bindNotFound))] == 1)
    }

    @Test("Sequential searches keep their branch's accumulated grade")
    func continuationKeepsProgress() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [1, 0], recorder: recorder) { index in
            guard index == 1 else {
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

        #expect(recorder.emissions == ["first0", "B0", "first1", "B1", "second0", "B2", "second1"])
    }

    @Test("Nested pools schedule independently without adding their costs to the parent")
    func nestedPoolsStayLocal() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let reducer = fixture.pool(costs: [0, 1], recorder: recorder) { index in
            guard index == 0 else {
                return fixture.search("B", values: [20], recorder: recorder)
            }
            return fixture.pool(costs: [100, 101], recorder: recorder) { childIndex in
                fixture.search(["X", "Y"][childIndex], values: [10, 11], recorder: recorder)
            }
        }

        let report = fixture.run(reducer)

        #expect(recorder.emissions == ["X0", "X1", "B0", "Y0", "Y1"])
        #expect(report.constructedSearches == 2)
        #expect(report.nestedConstructedSearches == 2)
    }

    @Test("The probe cap stops before opening another branch and finishes the pending search once")
    func probeCapAndFinishing() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: nil, totalProbeCap: 2)
        let reducer = fixture.pool(costs: [0, 100], configuration: configuration, recorder: recorder) { index in
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
        let reducer = fixture.pool(costs: [0, 1, 2], configuration: configuration, recorder: recorder) { index in
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
        let reducer = fixture.pool(costs: [0, 1, 2], configuration: configuration, recorder: recorder) { _ in
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
        let reducer = fixture.pool(costs: [0, 0], configuration: configuration, recorder: recorder) { index in
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
        let reducer = fixture.pool(costs: [0, 1], recorder: recorder) { index in
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
        let reducer = fixture.pool(costs: [0, 1], recorder: recorder) { index in
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

    @Test("The original turn-based policy remains available and ignores branch costs")
    func turnBasedComparison() throws {
        let fixture = try SchedulingFixture()
        let recorder = SchedulingRecorder()
        let configuration = ScopedChoiceConfiguration(probesPerSearchTurn: 2, searchBudget: nil, totalProbeCap: 0, scheduling: .turnBased)
        let reducer = fixture.pool(costs: [2, 0, 1], configuration: configuration, recorder: recorder) { index in
            fixture.search(["A", "B", "C"][index], recorder: recorder)
        }

        _ = fixture.run(reducer)

        #expect(recorder.emissions == ["A0", "A1", "B0", "B1", "C0", "C1", "A2", "B2", "C2"])
    }
}

// MARK: - Fixtures

/// Records actual branch construction, candidate emission, feedback, and finalization across interleaved searches.
private final class SchedulingRecorder {
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
        costs: [UInt],
        configuration: ScopedChoiceConfiguration = ScopedChoiceConfiguration(probesPerSearchTurn: nil, searchBudget: nil, totalProbeCap: 0),
        recorder: SchedulingRecorder,
        build: @escaping (Int) -> ScopedReducer
    ) -> ScopedReducer {
        let branches = costs.enumerated().map { index, cost in
            var prefix = sequence
            prefix[0] = prefix[0].withBitPattern(UInt64(index))
            return ScopedBranch(proposal: LiftProposal(prefix: prefix, mutation: .leafValues([])), cost: cost)
        }
        return .propose(branches, configuration: configuration) { proposal in
            guard let value = proposal.prefix[0].value else {
                preconditionFailure("Every fixture prefix starts with a value entry")
            }
            let index = Int(value.choice.bitPattern64)
            recorder.builds.append(index)
            recorder.events.append("build \(index)")
            return build(index)
        }
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
