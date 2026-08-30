//
//  ComparisonInjectionRuntimeTests.swift
//  ExhaustTests
//
//  End-to-end coverage for comparison-operand injection through the production `runExploreTimeCore` path. A fake CoverageSource supplied through the existing `source:` seam scripts the operands a trace-cmp build would harvest, so the run exercises wantsComparisons, the capture bracket, forEachComparisonRecord, the reconstructor and graft candidate paths, and the evaluateInjected attribution together — the whole feature, not a leaf.
//

import Exhaust
import ExhaustCore
import Testing

@Suite("Comparison Injection Runtime", .serialized)
struct ComparisonInjectionRuntimeTests {
    /// A wide constant a blind search over `0 ... Int.max` will not produce by chance in any reasonable budget.
    private let target = 0x5F37_59DF

    @Test("A wide-constant gate is solved when the comparison operand is supplied")
    func injectionSolvesWideConstantGate() {
        let report = runWideConstantGate(emitsComparisons: true)
        #expect(report.clusters.isEmpty == false)
        #expect(report.clusters.first?.reducedDescription == "\(target)")
    }

    @Test("The same gate stays unreachable when the operand is withheld")
    func withheldOperandLeavesTheGateUnreachable() {
        let report = runWideConstantGate(emitsComparisons: false)
        #expect(report.clusters.isEmpty)
    }

    @Test("A struct field-comparison gate is solved by the graft, exercising parent attribution")
    func graftSolvesStructFieldGate() {
        // A composite gate reaches reflectionGraftAttempt, so evaluateInjected records a candidate with a real parent — the attribution path the whole-value gate never touches.
        let report = runStructFieldGate(emitsComparisons: true)
        #expect(report.clusters.isEmpty == false)
        #expect(report.clusters.first?.reducedDescription.contains("\(target)") == true)
    }

    @Test("The struct gate stays unreachable when the operand is withheld")
    func graftUnreachableWhenOperandWithheld() {
        let report = runStructFieldGate(emitsComparisons: false)
        #expect(report.clusters.isEmpty)
    }

    @Test("Graft candidate production runs outside the attribution bracket that evaluates it")
    func graftProductionOutsideBracket() {
        // The attribution bracket encloses the property call only. The graft's `.exact` materializations execute the generator transform closure before the bracket opens, so their coverage never enters the injected attempt's signature, the same as every other candidate production path. Both the transform and the property record the count of opened brackets at the moment they run; the transform snapshot must predate the bracket that evaluated the candidate.
        let source = OperandScriptedSource(target: UInt64(target), emitsComparisons: true) { value in
            (value as? BracketProbePair).map { $0.first % 40 }
        }
        let events = UnsafeSendableBox<[BracketEvent]>([])
        // The transform must stay a simple initializer call over the bare parameters or #gen cannot synthesize the backward mapping, the generator stops being reflective, and the graft path under test never runs — so the probe lives in the composite's initializer instead of the closure body.
        BracketProbePair.onMaterialize = {
            events.value.append(.transform(bracket: source.attemptsOpened))
        }
        defer {
            BracketProbePair.onMaterialize = nil
        }
        let generator = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { first, second in
            BracketProbePair(first: first, second: second)
        }
        let report = __ExhaustRuntime.runExploreTimeCore(
            gen: generator.gen,
            generatorIsReflective: generator.isReflective,
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: source,
            configure: { configuration in
                configuration.attemptLimit = 20000
            },
            property: { [target] (pair: BracketProbePair) in
                events.value.append(.property(bracket: source.attemptsOpened, isTarget: pair.first == target))
                return pair.first == target ? .fail(.returnedFalse) : .pass
            }
        )
        #expect(report.clusters.isEmpty == false, "The graft must solve the gate for the bracket assertion to mean anything")

        let log = events.value
        let targetIndex = log.firstIndex { event in
            if case let .property(_, isTarget) = event {
                return isTarget
            }
            return false
        }
        guard let targetIndex, case let .property(targetBracket, _) = log[targetIndex] else {
            Issue.record("No property invocation reached the target value")
            return
        }
        let producedInsideBracket = log[..<targetIndex].contains { event in
            if case let .transform(bracket) = event {
                return bracket == targetBracket
            }
            return false
        }
        #expect(producedInsideBracket == false, "The injected candidate's materialization ran inside the attribution bracket that evaluated it")
    }

    // MARK: - Fixture

    private struct Pair: Equatable, Sendable {
        let first: Int
        let second: Int
    }

    private func runWideConstantGate(emitsComparisons: Bool) -> FuzzReport {
        // The generator is non-negative, so the edge projection needs no abs; abs would trap at Int.min on a signed generator.
        let source = OperandScriptedSource(target: UInt64(target), emitsComparisons: emitsComparisons) { value in
            (value as? Int).map { $0 % 40 }
        }
        return __ExhaustRuntime.runExploreTimeCore(
            gen: Gen.choose(in: 0 ... Int.max),
            generatorIsReflective: true,
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: source,
            configure: { configuration in
                configuration.attemptLimit = 20000
            },
            property: { [target] value in
                value == target ? .fail(.returnedFalse) : .pass
            }
        )
    }

    private func runStructFieldGate(emitsComparisons: Bool) -> FuzzReport {
        let generator = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { first, second in
            Pair(first: first, second: second)
        }
        let source = OperandScriptedSource(target: UInt64(target), emitsComparisons: emitsComparisons) { value in
            (value as? Pair).map { $0.first % 40 }
        }
        return __ExhaustRuntime.runExploreTimeCore(
            gen: generator.gen,
            generatorIsReflective: generator.isReflective,
            time: .seconds(60),
            settings: [.replay(1), .suppress(.all)],
            source: source,
            configure: { configuration in
                configuration.attemptLimit = 20000
            },
            property: { [target] pair in
                pair.first == target ? .fail(.returnedFalse) : .pass
            }
        )
    }
}

/// One observation for the bracket-placement test: which attribution bracket was open when a transform or property ran.
private enum BracketEvent {
    case transform(bracket: Int)
    case property(bracket: Int, isTarget: Bool)
}

/// The bracket test's composite: its initializer records which bracket was open when materialization built it, standing in for instrumented user code inside a generator transform. The hook is static because the transform closure must stay a bare initializer call for #gen to synthesize the backward mapping; the suite is `.serialized`, so the shared slot is never contended.
private struct BracketProbePair: Sendable {
    nonisolated(unsafe) static var onMaterialize: (() -> Void)?

    let first: Int
    let second: Int

    init(first: Int, second: Int) {
        Self.onMaterialize?()
        self.first = first
        self.second = second
    }
}

/// A fake coverage source that reports value-derived edges so the run seeds a corpus and reaches mutation, and scripts comparison records — the gate's constant under one site, plus a shallow decoy firing every attempt with varying operands under its own site, so injection must pick the target's site through the uniform site draw rather than being handed the only value in the pool.
private final class OperandScriptedSource: CoverageSource, @unchecked Sendable {
    let edgeCount = 64
    private let target: UInt64
    private let emitsComparisons: Bool
    private let edgeProjection: @Sendable (Any) -> Int?
    private var current: Any?
    private var decoyCounter: UInt64 = 0

    init(target: UInt64, emitsComparisons: Bool, edgeProjection: @escaping @Sendable (Any) -> Int?) {
        self.target = target
        self.emitsComparisons = emitsComparisons
        self.edgeProjection = edgeProjection
    }

    var wantsValues: Bool {
        true
    }

    /// The number of attribution brackets opened so far. The bracket-placement test reads it from the generator transform and the property to prove both execute inside the same bracket.
    private(set) var attemptsOpened = 0

    func beginAttempt() {
        current = nil
        attemptsOpened += 1
    }

    func noteValue(_ value: Any) {
        current = value
    }

    func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        guard let current, let edge = edgeProjection(current) else {
            return
        }
        body(edge, 1)
    }

    var wantsComparisons: Bool {
        emitsComparisons
    }

    func beginComparisonCapture() {}

    func endComparisonCapture() {}

    func forEachComparisonRecord(_ body: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void) {
        body(0xC0FFEE, target, target)
        decoyCounter &+= 1
        body(0xDECAF, decoyCounter, decoyCounter &* 0x9E37_79B9_7F4A_7C15)
    }
}
