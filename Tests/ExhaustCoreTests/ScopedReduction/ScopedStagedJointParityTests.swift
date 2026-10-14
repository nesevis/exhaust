import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped staged joint parity")
struct ScopedStagedJointParityTests {
    @Test(
        "Scoped staged joint reproduces the stages' trace, accounting, and result",
        arguments: StagedJointCase.all
    )
    func parity(stagedJointCase: StagedJointCase) throws {
        let fixture = try StagedJointFixture(stagedJointCase)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.counts)
        #expect(scoped.report.anyAccepted == legacy.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.anyRequiresRebuild)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.acceptedLeafNodeIDs)
        #expect(scoped.countsByArity == legacy.countsByArity)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test(
        "The stages the fixture drives match the reduction machine's staged joint pass",
        arguments: StagedJointCase.all
    )
    func legacyStagesMatchMachine(stagedJointCase: StagedJointCase) throws {
        let fixture = try StagedJointFixture(stagedJointCase)
        let legacy = fixture.runLegacy()
        var machine = try fixture.makeMachine()

        let accepted = machine.runStagedJointSearch()

        #expect(accepted == legacy.anyAccepted)
        #expect(machine.stats.numericSearchCountsByArity == legacy.countsByArity)
        #expect(machine.stats.encoderCounts[.stagedJointSearch] ?? ReductionProbeCounts() == legacy.counts)
        #expect(Array(machine.sequence) == Array(legacy.state.sequence))
    }

    @Test("Scoped discovery finds the checkpoint the reduction machine finds", arguments: StagedJointCase.all)
    func discoveryParity(stagedJointCase: StagedJointCase) throws {
        let fixture = try StagedJointFixture(stagedJointCase)
        let machine = try fixture.makeMachine()
        let legacyPool = NumericJointQuery.frontier(graph: machine.graph, gate: machine.convergence.gate)

        #expect(fixture.scope.pairs == NumericPairQuery.build(graph: machine.graph, gate: machine.convergence.gate))
        #expect(fixture.scope.candidatePool.map(\.leaf) == legacyPool.map(\.leaf))
        #expect(fixture.scope.candidatePool.map(\.stalled) == legacyPool.map(\.stalled))
        #expect(fixture.scope.candidatePool.map(\.span) == legacyPool.map(\.span))
        #expect(fixture.scope.candidatePool.map(\.simplifyingSamples) == legacyPool.map(\.simplifyingSamples))
        #expect(fixture.scope.candidatePool.map(\.compensatingSamples) == legacyPool.map(\.compensatingSamples))
    }

    @Test("A deadline that expires between stages starts no further stage", arguments: [1, 2])
    func deadlineBetweenStages(completedStages: Int) throws {
        let fixture = try StagedJointFixture(StagedJointCase.all[4])
        let complete = fixture.runScoped()
        #expect(complete.report.searchCounts.map(\.search) == [.stagedJoint(arity: 2), .stagedJoint(arity: 3), .stagedJoint(arity: 4)])
        let completed = complete.report.searchCounts.prefix(completedStages)
        let emissions = completed.reduce(0) { $0 + $1.counts.emitted }
        let checksAtLastProbe = try #require(complete.checksAtTermination[emissions])

        // The last completed stage's exhaustion check passes; the next check precedes the following stage.
        let interrupted = fixture.runScoped(deadlineAfterChecks: checksAtLastProbe + 1)

        #expect(interrupted.report.searchCounts == Array(completed))
        #expect(interrupted.report.counts.emitted == emissions)
    }

    @Test("The staged joint source offers the machine's pending checkpoint, priced as its first stage, and withholds it once searched", arguments: StagedJointCase.all)
    func sourceParity(stagedJointCase: StagedJointCase) throws {
        let fixture = try StagedJointFixture(stagedJointCase)
        var machine = try fixture.makeMachine()
        var source = fixture.makeSource(exhausted: nil)

        let priority = source.dispatchPriority
        let next = source.nextScope()
        let afterNext = source.nextScope()
        let priced = try #require(next)
        guard case let .stagedJoint(scope) = priced.opportunity else {
            Issue.record("Expected a staged joint opportunity")
            return
        }
        #expect(priced.priority == priority)
        #expect(scope == fixture.scope)
        #expect(scope.pairs == machine.pendingStagedNumericPairs())
        #expect(afterNext == nil)

        let legacy = fixture.runLegacy()
        #expect(priced.priority.estimatedCost == legacy.firstStageBudget)

        _ = machine.runStagedJointSearch()
        var searched = fixture.makeSource(exhausted: ScopedStagedJointSource.Checkpoint(base: fixture.sequence, scope: scope))
        let searchedPriority = searched.dispatchPriority
        #expect(searchedPriority == nil)
        #expect(machine.pendingStagedNumericPairs() == nil || legacy.anyAccepted)
    }

    @Test("The cases cover each arity's acceptance, closed escalation gates, and a shared budget spent without acceptance")
    func casesCoverStages() throws {
        let runs = try StagedJointCase.all.map { try StagedJointFixture($0).runLegacy() }

        #expect(runs.contains { run in run.countsByArity[2]?.accepted == 1 })
        #expect(runs.contains { run in run.countsByArity[3]?.accepted == 1 })
        #expect(runs.contains { run in run.countsByArity[4]?.accepted == 1 })
        #expect(runs.contains { run in run.anyAccepted == false && run.countsByArity[3] == nil && run.countsByArity[2] != nil })
        #expect(runs.contains { run in run.anyAccepted == false && run.countsByArity[3] != nil && run.countsByArity[4] == nil })
        #expect(runs.contains { run in run.anyAccepted == false && run.countsByArity[4] != nil })
    }
}

// MARK: - Cases

/// Values reflected through a zip of broad integer generators, a property over them, and the staged joint budgets.
struct StagedJointCase: CustomStringConvertible, Sendable {
    let label: String
    let values: [Int]
    let tuning: ScopedReductionTuning
    let passes: @Sendable ([Int]) -> Bool

    var description: String {
        label
    }

    static let all: [StagedJointCase] = [
        StagedJointCase(label: "pair sum", values: [3, 1, 1], tuning: ScopedReductionTuning()) { $0[0] + $0[1] != 4 },
        StagedJointCase(label: "proportional pair", values: [75, 100], tuning: ScopedReductionTuning()) { $0[0] * 4 != $0[1] * 3 },
        StagedJointCase(label: "Pythagorean triple", values: [75, 100, 125], tuning: ScopedReductionTuning()) { $0[0] * $0[0] + $0[1] * $0[1] != $0[2] * $0[2] },
        StagedJointCase(label: "three-way gate closed", values: [6, 8, 10], tuning: ScopedReductionTuning(threeWayNumericWorkLimit: 179)) { $0[0] * $0[0] + $0[1] * $0[1] != $0[2] * $0[2] },
        StagedJointCase(label: "linear quadruple", values: [2, 4, 6, 10], tuning: ScopedReductionTuning()) { $0[1] != 2 * $0[0] || $0[2] != 3 * $0[0] || $0[3] != 5 * $0[0] },
        StagedJointCase(label: "nonlinear quadruple", values: [2, 4, 5, 6], tuning: ScopedReductionTuning()) { $0[1] != $0[0] * $0[0] || $0[2] != 2 * $0[0] + 1 || $0[3] != $0[0] * $0[0] + $0[0] },
        StagedJointCase(label: "linear quadruple, three-way spends every calculation", values: [2, 4, 6, 10], tuning: ScopedReductionTuning(numericJointGroupCalculationLimit: 4)) { $0[1] != 2 * $0[0] || $0[2] != 3 * $0[0] || $0[3] != 5 * $0[0] },
        StagedJointCase(label: "four-way gate closed", values: [2, 4, 6, 10], tuning: ScopedReductionTuning(fourWayNumericWorkLimit: 215)) { $0[1] != 2 * $0[0] || $0[2] != 3 * $0[0] || $0[3] != 5 * $0[0] },
        StagedJointCase(label: "only the original fails, budget 7", values: [2, 4, 6, 10], tuning: ScopedReductionTuning(stagedJointProbeBudget: 7)) { $0 != [2, 4, 6, 10] },
        StagedJointCase(label: "only the original fails, budget 512", values: [2, 4, 6, 10], tuning: ScopedReductionTuning()) { $0 != [2, 4, 6, 10] },
    ]
}

// MARK: - Fixture

/// Reflects a case's values, marks every leaf converged so the checkpoint is stalled, and drives its stages both ways.
struct StagedJointFixture {
    struct LegacyRun {
        let events: [ProbeTraceRecorder.Event]
        let counts: ReductionProbeCounts
        let countsByArity: [Int: ReductionProbeCounts]
        let anyAccepted: Bool
        let anyRequiresRebuild: Bool
        let acceptedLeafNodeIDs: Set<Int>
        let firstStageBudget: Int
        let state: ProbeSessionFixtureState
    }

    struct ScopedRun {
        let events: [ProbeTraceRecorder.Event]
        let report: ScopedPassReport
        let result: ScopedReductionInterpreter.Result
        /// Deadline checks made by the time each probe ID terminated.
        let checksAtTermination: [Int: Int]

        /// Folds each stage's counts by arity, as the runner attributes them.
        var countsByArity: [Int: ReductionProbeCounts] {
            var byArity: [Int: ReductionProbeCounts] = [:]
            for searchCounts in report.searchCounts {
                guard case let .stagedJoint(arity) = searchCounts.search else {
                    continue
                }
                byArity[arity, default: ReductionProbeCounts()].merge(searchCounts.counts)
            }
            return byArity
        }
    }

    let stagedJointCase: StagedJointCase
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let scope: ScopedStagedJointEncoder.Scope
    let property: (Any) -> Bool

    init(_ stagedJointCase: StagedJointCase) throws {
        self.stagedJointCase = stagedJointCase
        let typed = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: stagedJointCase.values.count))
        let reflected = try #require(try Interpreters.reflect(typed, with: stagedJointCase.values))
        var built = ChoiceGraph.build(from: reflected)
        StagedJointFixture.markConverged(&built)
        let passes = stagedJointCase.passes
        generator = typed.erase()
        tree = reflected
        graph = built
        sequence = ChoiceSequence(reflected)
        property = { output in passes(output as! [Int]) }
        scope = ScopedStagedJointEncoder.Scope(
            pairs: ScopedStagedJointQuery.pairs(graph: built, isFruitlessBind: { _ in false }, tuning: stagedJointCase.tuning),
            candidatePool: ScopedStagedJointQuery.candidatePool(graph: built, isFruitlessBind: { _ in false }, tuning: stagedJointCase.tuning)
        )
    }

    /// The staged joint family over the fixture's stalled graph.
    func makeSource(exhausted: ScopedStagedJointSource.Checkpoint?) -> ScopedSource {
        ScopedSource.prepareStagedJointSource(
            from: graph,
            sequence: sequence,
            deferBindInner: false,
            isFruitlessBind: { _ in false },
            exhausted: exhausted,
            tuning: stagedJointCase.tuning
        )
    }

    /// A reduction machine at the same checkpoint, with the same budgets.
    func makeMachine() throws -> ReductionMachine {
        let typed = Gen.eachOf(Array(repeating: Gen.choose(in: 1 ... 1_000_000), count: stagedJointCase.values.count))
        let passes = stagedJointCase.passes
        var machine = ReductionMachine(
            gen: typed,
            initialTree: tree,
            initialOutput: stagedJointCase.values,
            config: .init(maxStalls: 2, enabledEncoders: [.stagedJointSearch], tuning: schedulerTuning),
            collectStats: true,
            property: { passes($0) }
        )
        machine.convergence.deferBindInner = false
        StagedJointFixture.markConverged(&machine.graph)
        return machine
    }

    /// Drives one probe session per stage, escalating as the reduction machine's staged joint pass does.
    func runLegacy() -> LegacyRun {
        let tuning = stagedJointCase.tuning
        var state = ProbeSessionFixtureState(
            sequence: sequence,
            tree: tree,
            output: stagedJointCase.values,
            graph: graph,
            gen: generator,
            property: property
        )
        var events: [ProbeTraceRecorder.Event] = []
        let gate = BoundValueGate(baseBudget: schedulerTuning.boundValueBaseBudget)
        let pairs = NumericPairQuery.build(graph: graph, gate: gate)
        let frontier = tuning.threeWayNumericWorkLimit > 0
            && tuning.numericJointGroupCalculationLimit > 0
            && tuning.numericJointScopeLimit > 0
            ? NumericJointQuery.frontier(graph: graph, gate: gate)
            : []
        let canTryThree = NumericJointQuery.canEscalate(frontier: frontier, arity: 3, workLimit: tuning.threeWayNumericWorkLimit)
        var budget = canTryThree ? max(1, tuning.stagedJointProbeBudget / 2) : tuning.stagedJointProbeBudget
        let firstStageBudget = budget
        var remaining = tuning.stagedJointProbeBudget
        var calculationsRemaining = tuning.numericJointGroupCalculationLimit
        var nextArity = 3
        var operation = GraphOperation.exchange(.stagedNumericPairs(pairs, probeBudget: budget))
        var counts = ReductionProbeCounts()
        var countsByArity: [Int: ReductionProbeCounts] = [:]
        var anyAccepted = false
        var anyRequiresRebuild = false
        var acceptedLeafNodeIDs: Set<Int> = []
        while true {
            // Each session numbers its probes from one; a scoped program numbers them across all its stages.
            let recorder = ProbeTraceRecorder()
            let report = runStage(operation, state: &state, recorder: recorder)
            events += recorder.events.map { $0.shiftingProbeID(by: counts.emitted) }
            counts.merge(report.counts)
            switch operation {
                case .exchange(.stagedNumericPairs):
                    countsByArity[2, default: ReductionProbeCounts()].merge(report.counts)
                case let .exchange(.numericJoint(groups, _)):
                    if let arity = groups.first?.leaves.count {
                        countsByArity[arity, default: ReductionProbeCounts()].merge(report.counts)
                    }
                default:
                    break
            }
            anyAccepted = anyAccepted || report.anyAccepted
            anyRequiresRebuild = anyRequiresRebuild || report.anyRequiresRebuild
            acceptedLeafNodeIDs.formUnion(report.acceptedLeafNodeIDs)
            if report.anyAccepted {
                break
            }
            remaining -= report.probeCount
            guard nextArity <= 4, canTryThree, remaining > 0, calculationsRemaining > 0 else {
                break
            }
            let arity = nextArity
            let threshold = arity == 3 ? tuning.threeWayNumericWorkLimit : tuning.fourWayNumericWorkLimit
            let found = NumericJointQuery.build(
                frontier: frontier,
                graph: graph,
                arity: arity,
                workLimit: threshold,
                calculationLimit: calculationsRemaining,
                scopeLimit: tuning.numericJointScopeLimit
            )
            calculationsRemaining -= found.calculations
            guard found.groups.isEmpty == false else {
                break
            }
            let reserveFour = arity == 3 && calculationsRemaining > 0
                && NumericJointQuery.canEscalate(frontier: frontier, arity: 4, workLimit: tuning.fourWayNumericWorkLimit)
            budget = reserveFour ? max(1, remaining / 2) : remaining
            nextArity += 1
            operation = .exchange(.numericJoint(found.groups, probeBudget: budget))
        }
        return LegacyRun(
            events: events,
            counts: counts,
            countsByArity: countsByArity,
            anyAccepted: anyAccepted,
            anyRequiresRebuild: anyRequiresRebuild,
            acceptedLeafNodeIDs: acceptedLeafNodeIDs,
            firstStageBudget: firstStageBudget,
            state: state
        )
    }

    /// - Parameter deadlineAfterChecks: Expires the deadline once this many checks have passed; nil never expires.
    func runScoped(deadlineAfterChecks: Int? = nil) -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let checks = CheckCounter()
        let input = EncoderInput(
            transformation: GraphTransformation(
                operation: .exchange(.stagedNumericPairs(scope.pairs, probeBudget: stagedJointCase.tuning.stagedJointProbeBudget)),
                priority: .zeroBenefit
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        let result = ScopedReductionInterpreter.run(
            ScopedStagedJointEncoder(tuning: stagedJointCase.tuning).reducer(scope, input: input),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: stagedJointCase.values)
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: false
                ),
                encoderName: .stagedJointSearch,
                deadlineCheck: {
                    checks.count += 1
                    guard let deadlineAfterChecks else {
                        return false
                    }
                    return checks.count > deadlineAfterChecks
                },
                observer: { [weak recorder] observation in
                    if case let .terminated(probeID, _, _) = observation {
                        checks.atTermination[probeID] = checks.count
                    }
                    recorder?.record(observation)
                }
            )
        )
        return ScopedRun(
            events: recorder.events,
            report: result.report,
            result: result,
            checksAtTermination: checks.atTermination
        )
    }

    // MARK: - Helpers

    private var schedulerTuning: SchedulerTuning {
        var schedulerTuning = SchedulerTuning()
        schedulerTuning.stagedJointProbeBudget = stagedJointCase.tuning.stagedJointProbeBudget
        schedulerTuning.threeWayNumericWorkLimit = stagedJointCase.tuning.threeWayNumericWorkLimit
        schedulerTuning.fourWayNumericWorkLimit = stagedJointCase.tuning.fourWayNumericWorkLimit
        schedulerTuning.numericJointGroupCalculationLimit = stagedJointCase.tuning.numericJointGroupCalculationLimit
        schedulerTuning.numericJointScopeLimit = stagedJointCase.tuning.numericJointScopeLimit
        return schedulerTuning
    }

    private func runStage(_ operation: GraphOperation, state: inout ProbeSessionFixtureState, recorder: ProbeTraceRecorder) -> PassReport {
        let transformation = GraphTransformation(operation: operation, priority: .zeroBenefit)
        var encoder = ChoiceGraphScheduler.selectEncoder(for: operation, gen: generator)
        encoder.start(scope: EncoderInput(
            transformation: transformation,
            baseSequence: state.sequence,
            tree: state.tree,
            graph: state.graph,
            warmStartRecords: [:]
        ))
        let session = ProbeSession(
            encoder: encoder,
            transformation: transformation,
            boundValueFingerprint: nil,
            baseSequence: state.sequence,
            hasBind: false,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        return session.runToCompletion(state: &state)
    }

    /// Settles every leaf at its current value, so each nontrivial leaf is a stalled source.
    private static func markConverged(_ graph: inout ChoiceGraph) {
        for nodeID in graph.leafNodes {
            guard case let .chooseBits(metadata) = graph.nodes[nodeID].kind else {
                continue
            }
            graph.convergenceStore[nodeID] = ConvergedOrigin(
                bound: metadata.value.bitPattern64,
                signal: .monotoneConvergence,
                configuration: .binarySearchSemanticSimplest,
                cycle: 0
            )
        }
    }
}

private extension ProbeTraceRecorder.Event {
    func shiftingProbeID(by offset: Int) -> Self {
        switch self {
            case let .emitted(probeID, sequence, mutation):
                .emitted(probeID + offset, sequence, mutation)
            case let .decoderSelected(probeID, preferExact, materializePicks):
                .decoderSelected(probeID + offset, preferExact: preferExact, materializePicks: materializePicks)
            case let .decoded(probeID, sequence):
                .decoded(probeID + offset, sequence)
            case let .terminated(probeID, disposition, materializationAttempts):
                .terminated(probeID + offset, disposition, materializationAttempts: materializationAttempts)
        }
    }
}

/// Counts deadline checks across an interpreter run.
private final class CheckCounter {
    var count = 0
    var atTermination: [Int: Int] = [:]
}
