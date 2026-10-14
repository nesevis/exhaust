import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped bound value parity")
struct ScopedBoundValueParityTests {
    @Test(
        "Scoped bound value reproduces the composition's trace, accounting, and result across nested chains",
        arguments: BoundValueCase.all
    )
    func parity(boundValueCase: BoundValueCase) throws {
        let fixture = try BoundValueFixture(boundValueCase)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(Set(scoped.report.searchReport.convergenceRecords.keys) == Set(legacy.report.convergenceRecords.keys))
        #expect(scoped.report.constructedSearches == legacy.report.composedUpstreamLifts)
        #expect(scoped.report.boundValueLiftAttempts == legacy.tally.total)
        #expect(scoped.report.boundValueBuildOutcomes == legacy.tally.counts)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test(
        "Scoped bound value stops at the same probe as the composition when the deadline expires",
        arguments: [1, 2, 3, 4, 5, 8, 13, 21]
    )
    func deadlineParity(checksBeforeExpiry: Int) throws {
        for boundValueCase in BoundValueCase.deadlineCases {
            let fixture = try BoundValueFixture(boundValueCase)
            let legacy = fixture.runLegacy(deadlineAfterChecks: checksBeforeExpiry)
            let scoped = fixture.runScoped(deadlineAfterChecks: checksBeforeExpiry)

            #expect(scoped.events == legacy.events.droppingSelectionsOfInterruptedProbes, "\(boundValueCase)")
            #expect(scoped.report.counts == legacy.report.counts, "\(boundValueCase)")
            #expect(scoped.report.boundValueBuildOutcomes == legacy.tally.counts, "\(boundValueCase)")
            #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence), "\(boundValueCase)")
        }
    }

    @Test("The cases cover nested searches, failed builds, acceptance after rejections, the probe cap, and suspended turns")
    func casesCoverCompositionPaths() throws {
        let runs = try BoundValueCase.all.map { boundValueCase in
            try (boundValueCase, BoundValueFixture(boundValueCase).runLegacy())
        }
        let outcomes = runs.flatMap { _, run in run.tally.counts.filter { $0.value > 0 }.map(\.key.outcome) }

        #expect(outcomes.contains(.nestedStage))
        #expect(outcomes.contains(.terminalSearch))
        #expect(outcomes.contains { outcome in outcome != .nestedStage && outcome != .terminalSearch })
        #expect(runs.contains { _, run in run.report.anyAccepted && run.report.probeCount > 1 })
        #expect(runs.contains { boundValueCase, run in
            boundValueCase.totalProbeCap > 0 && run.report.probeCount == boundValueCase.totalProbeCap
        })
        #expect(runs.contains { boundValueCase, run in
            run.tally.total == ChoiceGraphScheduler.nestedChainBuildPool(chainLength: boundValueCase.depth)
        })
        // More probes than two per constructed root search means some search resumed after a suspension.
        #expect(runs.contains { boundValueCase, run in
            boundValueCase.depth > 1 && run.report.probeCount > 2 * (run.report.composedUpstreamLifts ?? 0)
        })
    }
}

// MARK: - Cases

/// A chain of `depth` binds whose inner values accumulate into the terminal's shape. Each inner is drawn from `0 ... innerUpperBound` and reflected at `reflectedInner`. The terminal is either a scalar in `0 ... accumulated + 3` or an array whose length is the accumulated inner sum, so raising an inner lengthens the lift.
struct BoundValueCase: CustomStringConvertible, Sendable {
    enum Terminal: Sendable {
        case scalar
        case array
    }

    enum Property: Sendable {
        case alwaysFails
        case alwaysPasses
        /// Fails when the output's total is at least the threshold.
        case failsWhenTotalAtLeast(UInt64)
        /// Fails when the output's total is at most the threshold. Proposals that keep the total high pass first.
        case failsWhenTotalAtMost(UInt64)

        var closure: @Sendable (Any) -> Bool {
            switch self {
                case .alwaysFails:
                    { _ in false }
                case .alwaysPasses:
                    { _ in true }
                case let .failsWhenTotalAtLeast(threshold):
                    { output in BoundValueCase.total(of: output) < threshold }
                case let .failsWhenTotalAtMost(threshold):
                    { output in BoundValueCase.total(of: output) > threshold }
            }
        }
    }

    let depth: Int
    let terminal: Terminal
    var innerUpperBound: UInt64 = 5
    var reflectedInner: UInt64 = 2
    var upstreamBudget = 15
    var totalProbeCap = 0
    let property: Property

    var description: String {
        "depth \(depth), \(terminal), inner ≤ \(innerUpperBound) at \(reflectedInner), budget \(upstreamBudget), cap \(totalProbeCap), \(property)"
    }

    static func total(of output: Any) -> UInt64 {
        if let scalar = output as? UInt64 {
            return scalar
        }
        return (output as! [UInt64]).reduce(0, +)
    }

    static let all: [BoundValueCase] = [
        BoundValueCase(depth: 1, terminal: .scalar, property: .alwaysFails),
        BoundValueCase(depth: 1, terminal: .scalar, property: .alwaysPasses),
        BoundValueCase(depth: 1, terminal: .scalar, property: .failsWhenTotalAtLeast(4)),
        BoundValueCase(depth: 2, terminal: .scalar, property: .alwaysFails),
        BoundValueCase(depth: 2, terminal: .scalar, property: .alwaysPasses),
        BoundValueCase(depth: 2, terminal: .scalar, property: .failsWhenTotalAtMost(2)),
        BoundValueCase(depth: 3, terminal: .scalar, upstreamBudget: 4, property: .alwaysPasses),
        BoundValueCase(depth: 3, terminal: .scalar, upstreamBudget: 4, totalProbeCap: 16, property: .alwaysPasses),
        BoundValueCase(depth: 3, terminal: .scalar, property: .failsWhenTotalAtMost(1)),
        BoundValueCase(depth: 2, terminal: .array, property: .alwaysPasses),
        BoundValueCase(depth: 2, terminal: .array, property: .failsWhenTotalAtLeast(12)),
        BoundValueCase(depth: 1, terminal: .array, property: .alwaysPasses),
        BoundValueCase(depth: 3, terminal: .scalar, innerUpperBound: 50, reflectedInner: 20, property: .alwaysPasses),
    ]

    static let deadlineCases: [BoundValueCase] = [
        BoundValueCase(depth: 2, terminal: .scalar, property: .alwaysPasses),
        BoundValueCase(depth: 3, terminal: .scalar, property: .failsWhenTotalAtMost(1)),
        BoundValueCase(depth: 1, terminal: .scalar, property: .failsWhenTotalAtLeast(4)),
    ]
}

// MARK: - Fixture

/// Builds the dispatched bound value scope for the outermost bind and runs the composition and the scoped program against separate copies of the state.
struct BoundValueFixture {
    struct LegacyRun {
        let events: [ProbeTraceRecorder.Event]
        let report: PassReport
        let state: ProbeSessionFixtureState
        let tally: BoundValueBuildTally
    }

    struct ScopedRun {
        let events: [ProbeTraceRecorder.Event]
        let report: ScopedPassReport
        let result: ScopedReductionInterpreter.Result
    }

    let boundValueCase: BoundValueCase
    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let bindScope: BoundValueScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: Any

    init(_ boundValueCase: BoundValueCase) throws {
        self.boundValueCase = boundValueCase
        generator = Self.chain(boundValueCase, remaining: boundValueCase.depth, accumulated: 0)
        let accumulated = UInt64(boundValueCase.depth) * boundValueCase.reflectedInner
        output = switch boundValueCase.terminal {
            case .scalar:
                accumulated + 1
            case .array:
                [UInt64](repeating: 5, count: Int(accumulated))
        }
        let reflected = try #require(try Interpreters.reflect(generator, with: output))
        let built = ChoiceGraph.build(from: reflected)
        let flattened = ChoiceSequence.flatten(reflected)
        let bindNodeID = try #require(built.liveNodeIDs.first { nodeID in
            guard case .bind = built.nodes[nodeID].kind else {
                return false
            }
            return true
        })
        guard case let .bind(metadata) = built.nodes[bindNodeID].kind else {
            throw BoundValueFixtureError.missingBind
        }
        tree = reflected
        graph = built
        sequence = flattened
        bindScope = BoundValueScope(
            bindNodeID: bindNodeID,
            upstreamLeafNodeID: built.nodes[bindNodeID].children[metadata.innerChildIndex],
            downstreamNodeIDs: Array(built.leafNodes.dropFirst()),
            boundSubtreeSize: flattened.count
        )
        scope = EncoderInput(
            transformation: GraphTransformation(
                operation: .minimize(.boundValue(bindScope)),
                priority: .zeroBenefit
            ),
            baseSequence: sequence,
            tree: tree,
            graph: graph,
            warmStartRecords: [:]
        )
        property = boundValueCase.property.closure
    }

    func runLegacy(deadlineAfterChecks: Int? = nil) -> LegacyRun {
        var state = ProbeSessionFixtureState(
            sequence: sequence,
            tree: tree,
            output: output,
            graph: graph,
            gen: generator,
            property: property
        )
        let tally = BoundValueBuildTally()
        let recorder = ProbeTraceRecorder()
        var encoder = ChoiceGraphScheduler.makeBoundValueComposition(
            bindScope: bindScope,
            scope: scope,
            graph: graph,
            gen: generator,
            upstreamBudget: boundValueCase.upstreamBudget,
            totalProbeCap: boundValueCase.totalProbeCap,
            buildTally: tally
        )
        encoder.start(scope: scope)
        let session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: true,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state, deadlineCheck: deadlineAfterChecks.map(DeadlineCounter.check(expiringAfter:)))
        return LegacyRun(events: recorder.events, report: report, state: state, tally: tally)
    }

    func runScoped(deadlineAfterChecks: Int? = nil) -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedBoundValueEncoder(tuning: ScopedReductionTuning()).reducer(
                ScopedBoundValueEncoder.Scope(
                    bindScope: bindScope,
                    upstreamBudget: boundValueCase.upstreamBudget,
                    totalProbeCap: boundValueCase.totalProbeCap
                ),
                input: scope
            ),
            context: ScopedReductionInterpreter.Context(
                incumbent: ScopedCounterexample(
                    sequence: sequence,
                    tree: tree,
                    output: ScopedOutputHandle(value: output)
                ),
                graph: graph,
                rejectCache: [],
                decoder: ScopedDecoder(
                    generator: generator,
                    property: property,
                    probeWrapper: nil,
                    hasBind: true
                ),
                encoderName: .composed,
                deadlineCheck: deadlineAfterChecks.map(DeadlineCounter.check(expiringAfter:)),
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }

    /// One bind per remaining level, each with its own fingerprint so the chain is composable.
    private static func chain(_ boundValueCase: BoundValueCase, remaining: Int, accumulated: UInt64) -> AnyGenerator {
        guard remaining > 0 else {
            return switch boundValueCase.terminal {
                case .scalar:
                    Gen.choose(in: UInt64(0) ... accumulated + 3).erase()
                case .array:
                    Gen.arrayOf(Gen.choose(in: UInt64(0) ... 9), within: accumulated ... accumulated, scaling: .constant).erase()
            }
        }
        let outputType: Any.Type = switch boundValueCase.terminal {
            case .scalar:
                UInt64.self
            case .array:
                [UInt64].self
        }
        let reflectedInner = boundValueCase.reflectedInner
        return .impure(
            operation: .transform(
                kind: .bind(
                    fingerprint: UInt64(remaining),
                    forward: { input in
                        chain(boundValueCase, remaining: remaining - 1, accumulated: accumulated + (input as! UInt64))
                    },
                    backward: { _ in reflectedInner },
                    inputType: UInt64.self,
                    outputType: outputType
                ),
                inner: Gen.choose(in: UInt64(0) ... boundValueCase.innerUpperBound).erase()
            ),
            continuation: { .pure($0) }
        )
    }
}

private enum BoundValueFixtureError: Error {
    case missingBind
}

/// A deadline that expires on its `checks`-th query and stays expired, so both reducers see expiry at the same check.
private final class DeadlineCounter {
    private var checksRemaining: Int

    private init(checks: Int) {
        checksRemaining = checks
    }

    static func check(expiringAfter checks: Int) -> () -> Bool {
        let counter = DeadlineCounter(checks: checks)
        return {
            counter.checksRemaining -= 1
            return counter.checksRemaining < 0
        }
    }
}

private extension [ProbeTraceRecorder.Event] {
    /// The scoped interpreter selects its decoder while decoding, after the deadline check, so a probe interrupted there has no selection event. The session selects before that check.
    var droppingSelectionsOfInterruptedProbes: [ProbeTraceRecorder.Event] {
        let interruptedProbeIDs = Set(compactMap { event -> Int? in
            guard case let .terminated(probeID, .interrupted, _) = event else {
                return nil
            }
            return probeID
        })
        return filter { event in
            guard case let .decoderSelected(probeID, _, _) = event else {
                return true
            }
            return interruptedProbeIDs.contains(probeID) == false
        }
    }
}
