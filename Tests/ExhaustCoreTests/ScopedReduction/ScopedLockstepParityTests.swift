import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Scoped lockstep parity")
struct ScopedLockstepParityTests {
    @Test(
        "Scoped lockstep reproduces the encoder's trace, accounting, and result",
        arguments: LockstepCase.all
    )
    func parity(lockstepCase: LockstepCase) throws {
        let fixture = try LockstepFixture(lockstepCase)
        let legacy = fixture.runLegacy()
        let scoped = fixture.runScoped()

        #expect(scoped.events == legacy.events)
        #expect(scoped.report.counts == legacy.report.counts)
        #expect(scoped.report.anyAccepted == legacy.report.anyAccepted)
        #expect(scoped.report.anyRequiresRebuild == legacy.report.anyRequiresRebuild)
        #expect(scoped.report.latestTreeIsStripped == legacy.report.latestTreeIsStripped)
        #expect(scoped.report.acceptedLeafNodeIDs == legacy.report.acceptedLeafNodeIDs)
        #expect(scoped.report.searchReport.convergenceRecords == legacy.report.convergenceRecords)
        #expect(Array(scoped.result.incumbent.sequence) == Array(legacy.state.sequence))
        #expect(scoped.result.rejectCache == legacy.state.rejectCache)
    }

    @Test("The cases cover accepted shifts of unsigned, signed, float, and character groups, and a search that rejects every probe")
    func casesCoverSearchPaths() throws {
        let runs = try LockstepCase.all.map { lockstepCase in
            try (lockstepCase, LockstepFixture(lockstepCase).runLegacy())
        }

        #expect(runs.contains { lockstepCase, run in lockstepCase.kind == .unsigned && run.report.anyAccepted })
        #expect(runs.contains { lockstepCase, run in lockstepCase.kind == .signed && run.report.anyAccepted })
        #expect(runs.contains { lockstepCase, run in lockstepCase.kind == .floats && run.report.anyAccepted })
        #expect(runs.contains { lockstepCase, run in lockstepCase.kind == .characters && run.report.anyAccepted })
        #expect(runs.contains { _, run in run.report.anyAccepted == false && run.report.probeCount > 1 })
    }
}

// MARK: - Cases

/// A generator family, a value reflected through it, and a property over the reflected output.
struct LockstepCase: CustomStringConvertible, Sendable {
    enum Kind: Sendable {
        case unsigned
        case signed
        case floats
        case characters
    }

    let label: String
    let kind: Kind
    let value: [Double]
    let fails: @Sendable ([Double]) -> Bool

    var description: String {
        label
    }

    static let all: [LockstepCase] = [
        LockstepCase(label: "unsigned, equal and large", kind: .unsigned, value: [200, 200, 200], fails: { $0[0] == $0[1] && $0[1] == $0[2] && $0[0] >= 50 }),
        LockstepCase(label: "unsigned, equal pair", kind: .unsigned, value: [200, 200, 9], fails: { $0[0] == $0[1] && $0[0] >= 50 }),
        LockstepCase(label: "unsigned, never fails", kind: .unsigned, value: [200, 200, 200], fails: { _ in false }),
        LockstepCase(label: "signed, equal and far from zero", kind: .signed, value: [-40, -40], fails: { $0[0] == $0[1] && $0[0] <= -10 }),
        LockstepCase(label: "characters, equal and late", kind: .characters, value: [Double(Character("q").unicodeScalars.first!.value), Double(Character("q").unicodeScalars.first!.value)], fails: { $0[0] == $0[1] && $0[0] >= Double(Character("c").unicodeScalars.first!.value) }),
        LockstepCase(label: "floats, equal and large", kind: .floats, value: [125.5, 125.5], fails: { $0[0] == $0[1] && $0[0] >= 20 }),
    ]
}

// MARK: - Fixture

/// Reflects a case's value through its generator family and dispatches the first tandem scope ``ExchangeQuery`` builds for it.
struct LockstepFixture {
    struct LegacyRun {
        let events: [ProbeTraceRecorder.Event]
        let report: PassReport
        let state: ProbeSessionFixtureState
    }

    struct ScopedRun {
        let events: [ProbeTraceRecorder.Event]
        let report: ScopedPassReport
        let result: ScopedReductionInterpreter.Result
    }

    let generator: AnyGenerator
    let tree: ChoiceTree
    let graph: ChoiceGraph
    let sequence: ChoiceSequence
    let tandemScope: TandemScope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: Any

    init(_ lockstepCase: LockstepCase) throws {
        let fails = lockstepCase.fails
        let reflected: ChoiceTree
        switch lockstepCase.kind {
            case .unsigned:
                let typed = Gen.zip(
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000)
                )
                let value = (UInt64(lockstepCase.value[0]), UInt64(lockstepCase.value[1]), UInt64(lockstepCase.value[2]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second, third) = output as! (UInt64, UInt64, UInt64)
                    return fails([Double(first), Double(second), Double(third)]) == false
                }
            case .signed:
                let typed = Gen.zip(Gen.choose(in: Int64(-100) ... 100), Gen.choose(in: Int64(-100) ... 100))
                let value = (Int64(lockstepCase.value[0]), Int64(lockstepCase.value[1]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Int64, Int64)
                    return fails([Double(first), Double(second)]) == false
                }
            case .characters:
                let typed = Gen.zip(Gen.character(in: "a" ... "z").gen, Gen.character(in: "a" ... "z").gen)
                let value = (Character(Unicode.Scalar(UInt32(lockstepCase.value[0]))!), Character(Unicode.Scalar(UInt32(lockstepCase.value[1]))!))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Character, Character)
                    return fails([Double(first.unicodeScalars.first!.value), Double(second.unicodeScalars.first!.value)]) == false
                }
            case .floats:
                let typed = Gen.zip(Gen.choose(in: 0.0 ... 1000.0), Gen.choose(in: 0.0 ... 1000.0))
                let value = (lockstepCase.value[0], lockstepCase.value[1])
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Double, Double)
                    return fails([first, second]) == false
                }
        }
        let built = ChoiceGraph.build(from: reflected)
        let found = ExchangeQuery.build(graph: built).compactMap { scope -> TandemScope? in
            guard case let .tandem(tandemScope) = scope else {
                return nil
            }
            return tandemScope
        }
        let flattened = ChoiceSequence(reflected)
        tree = reflected
        graph = built
        sequence = flattened
        tandemScope = try #require(found.first)
        scope = EncoderInput(
            transformation: GraphTransformation(operation: .exchange(.tandem(tandemScope)), priority: .zeroBenefit),
            baseSequence: flattened,
            tree: reflected,
            graph: built,
            warmStartRecords: [:]
        )
    }

    func runLegacy() -> LegacyRun {
        var state = ProbeSessionFixtureState(
            sequence: sequence,
            tree: tree,
            output: output,
            graph: graph,
            gen: generator,
            property: property
        )
        let recorder = ProbeTraceRecorder()
        var encoder = ChoiceGraphScheduler.selectEncoder(for: scope.transformation.operation, gen: generator)
        encoder.start(scope: scope)
        let session = ProbeSession(
            encoder: encoder,
            transformation: scope.transformation,
            boundValueFingerprint: nil,
            baseSequence: sequence,
            hasBind: false,
            observer: { [weak recorder] in recorder?.record($0) }
        )
        let report = session.runToCompletion(state: &state)
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    func runScoped() -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedLockstepEncoder(tuning: ScopedReductionTuning()).reducer(tandemScope, input: scope),
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
                    hasBind: false
                ),
                encoderName: .lockstep,
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}
