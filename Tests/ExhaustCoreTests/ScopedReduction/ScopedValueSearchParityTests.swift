import ExhaustTestSupport
import Foundation
import Testing
@testable import ExhaustCore

@Suite("Scoped value search parity")
struct ScopedValueSearchParityTests {
    @Test(
        "Scoped value search reproduces the encoder's trace, accounting, convergence, and result",
        arguments: ValueCase.all
    )
    func parity(valueCase: ValueCase) throws {
        let fixture = try ValueSearchFixture(valueCase)
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

    @Test("The cases reach batch zero, bisection, cross-zero, gap scans, character simplification, every float stage, and the deadline flush")
    func casesCoverSearchPaths() throws {
        let runs = try ValueCase.all.map { valueCase in
            try (valueCase, ValueSearchFixture(valueCase).runLegacy())
        }

        #expect(runs.contains { valueCase, run in valueCase.kind == .unsigned && run.report.anyAccepted })
        #expect(runs.contains { valueCase, run in valueCase.kind == .unsignedWide && run.report.anyAccepted })
        #expect(runs.contains { valueCase, run in valueCase.kind == .signed && run.report.anyAccepted })
        #expect(runs.contains { valueCase, run in valueCase.kind == .characters && run.report.anyAccepted })
        #expect(runs.contains { valueCase, run in valueCase.kind == .floats && run.report.anyAccepted })
        #expect(runs.contains { _, run in run.report.anyAccepted == false && run.report.probeCount > 1 })
        #expect(runs.contains { _, run in run.report.convergenceRecords.values.contains { origin in if case .scanComplete = origin.signal { true } else { false } } })
        #expect(runs.contains { valueCase, run in valueCase.deadlineAfterChecks != nil && run.report.convergenceRecords.isEmpty == false })
    }
}

// MARK: - Cases

/// A generator family, a value reflected through it, and a property over the reflected output.
struct ValueCase: CustomStringConvertible, Sendable {
    enum Kind: Sendable {
        case unsigned
        /// Five leaves, enough for batch bisection, which needs at least four unconverged leaves.
        case unsignedWide
        case signed
        case characters
        case floats
    }

    let label: String
    let kind: Kind
    let value: [Double]
    let fails: @Sendable ([Double]) -> Bool
    /// Expires the deadline after this many checks, so the search is interrupted mid-leaf.
    var deadlineAfterChecks: Int?

    var description: String {
        label
    }

    static let all: [ValueCase] = [
        ValueCase(label: "unsigned, sum at least 300", kind: .unsigned, value: [500, 700, 20], fails: { $0.reduce(0, +) >= 300 }),
        ValueCase(label: "unsigned, always fails", kind: .unsigned, value: [500, 700, 20], fails: { _ in true }),
        ValueCase(label: "unsigned, never fails", kind: .unsigned, value: [500, 700, 20], fails: { _ in false }),
        ValueCase(label: "unsigned wide, every leaf large", kind: .unsignedWide, value: [500, 700, 300, 900, 400], fails: { $0.allSatisfy { leaf in leaf >= 100 } }),
        ValueCase(label: "unsigned wide, sum large", kind: .unsignedWide, value: [500, 700, 300, 900, 400], fails: { $0.reduce(0, +) >= 1500 }),
        ValueCase(label: "unsigned, residue gap", kind: .unsigned, value: [500, 700, 20], fails: { Int($0[0]) % 7 == 3 && $0[1] >= 5 }),
        ValueCase(label: "unsigned, interrupted early", kind: .unsigned, value: [500, 700, 20], fails: { $0.reduce(0, +) >= 300 }, deadlineAfterChecks: 9),
        ValueCase(label: "unsigned, interrupted mid-leaf", kind: .unsigned, value: [500, 700, 20], fails: { $0.reduce(0, +) >= 300 }, deadlineAfterChecks: 21),
        ValueCase(label: "unsigned, interrupted late", kind: .unsigned, value: [500, 700, 20], fails: { $0.reduce(0, +) >= 300 }, deadlineAfterChecks: 35),
        ValueCase(label: "signed, magnitude", kind: .signed, value: [37, -45], fails: { abs($0[0]) >= 10 || $0[1] < -20 }),
        ValueCase(label: "signed, negative only", kind: .signed, value: [37, -45], fails: { $0[0] < 5 && $0[1] < 0 }),
        ValueCase(label: "characters", kind: .characters, value: [Double(Character("q").unicodeScalars.first!.value), 7], fails: { $0[0] >= Double(Character("c").unicodeScalars.first!.value) }),
        ValueCase(label: "floats, threshold", kind: .floats, value: [123.456, -7.25], fails: { $0[0] >= 10.5 || $0[1] < -3 }),
        ValueCase(label: "floats, fraction", kind: .floats, value: [123.456, -7.25], fails: { $0[0] > 0.3 }),
    ]
}

// MARK: - Fixture

/// Reflects a case's value through its generator family and dispatches the first integer or float minimization scope ``MinimizationQuery`` builds for it.
struct ValueSearchFixture {
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
    let searchScope: ScopedValueSearch.Scope
    let scope: EncoderInput
    let property: (Any) -> Bool
    let output: Any
    let deadlineAfterChecks: Int?

    init(_ valueCase: ValueCase) throws {
        let fails = valueCase.fails
        let reflected: ChoiceTree
        switch valueCase.kind {
            case .unsigned:
                let typed = Gen.zip(
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000)
                )
                let value = (UInt64(valueCase.value[0]), UInt64(valueCase.value[1]), UInt64(valueCase.value[2]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second, third) = output as! (UInt64, UInt64, UInt64)
                    return fails([Double(first), Double(second), Double(third)]) == false
                }
            case .unsignedWide:
                let typed = Gen.zip(
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000),
                    Gen.choose(in: UInt64(0) ... 1000)
                )
                let leaves = valueCase.value.map { leaf in UInt64(leaf) }
                let value = (leaves[0], leaves[1], leaves[2], leaves[3], leaves[4])
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second, third, fourth, fifth) = output as! (UInt64, UInt64, UInt64, UInt64, UInt64)
                    return fails([first, second, third, fourth, fifth].map { leaf in Double(leaf) }) == false
                }
            case .signed:
                let typed = Gen.zip(Gen.choose(in: Int64(-100) ... 100), Gen.choose(in: Int64(-100) ... 100))
                let value = (Int64(valueCase.value[0]), Int64(valueCase.value[1]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Int64, Int64)
                    return fails([Double(first), Double(second)]) == false
                }
            case .characters:
                let typed = Gen.zip(Gen.character(in: "a" ... "z").gen, Gen.choose(in: UInt64(0) ... 9))
                let value = (Character(Unicode.Scalar(UInt32(valueCase.value[0]))!), UInt64(valueCase.value[1]))
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (character, number) = output as! (Character, UInt64)
                    return fails([Double(character.unicodeScalars.first!.value), Double(number)]) == false
                }
            case .floats:
                let typed = Gen.zip(Gen.choose(in: 0.0 ... 1000.0), Gen.choose(in: -50.0 ... 50.0))
                let value = (valueCase.value[0], valueCase.value[1])
                reflected = try #require(try Interpreters.reflect(typed, with: value))
                generator = typed.erase()
                output = value
                property = { output in
                    let (first, second) = output as! (Double, Double)
                    return fails([first, second]) == false
                }
        }
        let built = ChoiceGraph.build(from: reflected)
        let minimizationScope = try #require(MinimizationQuery.build(graph: built, deferBindInner: false).first { scope in
            switch scope {
                case .valueLeaves, .floatLeaves:
                    true
                default:
                    false
            }
        })
        let flattened = ChoiceSequence(reflected)
        tree = reflected
        graph = built
        sequence = flattened
        searchScope = switch minimizationScope {
            case let .valueLeaves(integerScope):
                .integer(integerScope)
            case let .floatLeaves(floatScope):
                .float(floatScope)
            default:
                preconditionFailure("Filtered to value and float scopes above")
        }
        scope = EncoderInput(
            transformation: GraphTransformation(operation: .minimize(minimizationScope), priority: .zeroBenefit),
            baseSequence: flattened,
            tree: reflected,
            graph: built,
            warmStartRecords: [:]
        )
        deadlineAfterChecks = valueCase.deadlineAfterChecks
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
        let report = session.runToCompletion(state: &state, deadlineCheck: deadlineAfterChecks.map(ValueDeadlineCounter.check(expiringAfter:)))
        return LegacyRun(events: recorder.events, report: report, state: state)
    }

    func runScoped() -> ScopedRun {
        let recorder = ProbeTraceRecorder()
        let result = ScopedReductionInterpreter.run(
            ScopedValueSearchEncoder(tuning: ScopedReductionTuning()).reducer(searchScope, input: scope),
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
                encoderName: .valueSearch,
                deadlineCheck: deadlineAfterChecks.map(ValueDeadlineCounter.check(expiringAfter:)),
                observer: { [weak recorder] in recorder?.record($0) }
            )
        )
        return ScopedRun(events: recorder.events, report: result.report, result: result)
    }
}

/// A deadline that expires on its `checks`-th query and stays expired, so both reducers see expiry at the same check.
private final class ValueDeadlineCounter {
    private var checksRemaining: Int

    private init(checks: Int) {
        checksRemaining = checks
    }

    static func check(expiringAfter checks: Int) -> () -> Bool {
        let counter = ValueDeadlineCounter(checks: checks)
        return {
            counter.checksRemaining -= 1
            return counter.checksRemaining < 0
        }
    }
}
