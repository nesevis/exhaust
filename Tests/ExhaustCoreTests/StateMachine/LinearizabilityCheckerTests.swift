import Testing
@testable import ExhaustCore

/// Tests the linearizability checker directly, using hand-built histories and a stack model.
///
/// The checker answers one question: could the values seen during a concurrent run have come from running the commands one at a time, in some order that keeps each lane's commands in their original sequence? Commands on the same lane must stay in order; commands on different lanes may be tried in either order.
///
/// A stack makes a good model because its answers depend on order. A `pop` returns the value pushed last, or reports a skip when the stack is empty, so a wrong return value (a value that was never pushed) and a wrong final state are both easy to build. Each test supplies fixed observations and a fixed final state, so the verdict is deterministic. There are no real threads.
@Suite("Linearizability checker")
struct LinearizabilityCheckerTests {
    // MARK: - Queue False Positive Reproduction

    @Test("Dequeue-nil with concurrent enqueues is linearizable when a valid ordering exists")
    func dequeueNilWithConcurrentEnqueuesIsLinearizable() {
        // Reproduces the false positive from the Herlihy queue test:
        // Lane A: dequeue → nil, enqueue(41)
        // Lane B: enqueue(7), enqueue(78), enqueue(96)
        // Queue starts empty (prefix was 4 dequeues on empty queue).
        // Valid ordering: A1(dequeue→nil), A2(enqueue(41)), B1(enqueue(7)), B2(enqueue(78)), B3(enqueue(96))
        //   → state [41, 7, 78, 96]
        // The concurrent execution produced [41, 78, 96] (enqueue(7) lost),
        // but for the false positive case, assume the concurrent state is [41, 78, 96]
        // with only 3 items — that IS genuinely non-linearizable (lost item).
        // The actual false positive had same-multiset: expected [78, 96, 41], actual [41, 78, 96].
        // Test the same-multiset case: all 4 items present, just reordered.
        let laneA: [QueueObservation] = [dequeueReturningNil(), enqueue(41)]
        let laneB: [QueueObservation] = [enqueue(7), enqueue(78), enqueue(96)]
        // State [41, 7, 78, 96] = ordering A1, A2, B1, B2, B3
        let result = queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [41, 7, 78, 96]))
        #expect(result.linearizable, "Ordering (dequeue→nil, enqueue(41), enqueue(7), enqueue(78), enqueue(96)) produces this state")
    }

    @Test("All reorderings of enqueue-only lanes are linearizable")
    func allEnqueueReorderingsAreLinearizable() {
        // Lane A: enqueue(1), enqueue(2)
        // Lane B: enqueue(3)
        // Every valid ordering produces 3 items; the item positions vary.
        let laneA: [QueueObservation] = [enqueue(1), enqueue(2)]
        let laneB: [QueueObservation] = [enqueue(3)]
        // A1, A2, B1 → [1, 2, 3]
        #expect(queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [1, 2, 3])).linearizable)
        // A1, B1, A2 → [1, 3, 2]
        #expect(queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [1, 3, 2])).linearizable)
        // B1, A1, A2 → [3, 1, 2]
        #expect(queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [3, 1, 2])).linearizable)
    }

    // MARK: - Stack Tests

    @Test("No commands is trivially linearizable")
    func emptyHistoryIsLinearizable() {
        #expect(verdict(check(lanes: [], finalState: [])).linearizable)
        #expect(verdict(check(lanes: [[]], finalState: [])).linearizable)
    }

    @Test("Either order of two overlapping pushes is accepted")
    func eitherOrderOfConcurrentPushesIsAccepted() {
        // Two lanes each push one value. The stack ends up in whichever order the run happened to pick; both are valid, and the checker must accept the one that matches the observed final state. This is the case a fixed-order oracle gets wrong roughly half the time.
        let lanes = [[push(1)], [push(2)]]
        #expect(verdict(check(lanes: lanes, finalState: [1, 2])).linearizable)
        #expect(verdict(check(lanes: lanes, finalState: [2, 1])).linearizable)
    }

    @Test("A pop returning a never-pushed value is not linearizable and names the pop")
    func ghostPopValueIsNotLinearizableAndNamesIt() {
        // Lane A pushes 1. Lane B's pop reports 9, a value that was never pushed; only 1 was. No order reproduces that return value, so the run is not linearizable and the witness points at lane B's pop.
        let lanes = [[push(1)], [popReturning(9)]]
        let (linearizable, witness) = verdict(check(lanes: lanes, finalState: [1]))
        #expect(linearizable == false)
        #expect(witness?.lane == 1)
        #expect(witness?.command == 0)
    }

    @Test("Wrong final state with correct responses has no command witness")
    func lostUpdateIsNotLinearizableWithNoWitness() {
        // Two pushes, but the final state shows only one value, a lost update. Every command returned void, so no single return value is wrong; only the final state disagrees. The checker reports not-linearizable with no command witness, because the disagreement is visible in the expected-versus-actual state, not in any one command.
        let lanes = [[push(1)], [push(2)]]
        let (linearizable, witness) = verdict(check(lanes: lanes, finalState: [1]))
        #expect(linearizable == false)
        #expect(witness == nil)
    }

    @Test("Witness names the impossible command via the deepest matching prefix, not the first mismatch")
    func witnessPicksDeepestDivergence() {
        // Lane A pushes 1 then pops expecting 2, but 2 is never pushed, so A's pop is the one impossible command. Lane B pops expecting 1, which is fine after the push. The orderings fail at different depths: starting with B's pop hits an empty stack at the first command (a shallow mismatch on a command that is innocent — it only failed because it ran first), whereas push(1), B's pop→1, then A's pop reproduces two commands before A's pop fails on the now-empty stack. The checker keeps the command at the deepest matching prefix, so the witness is A's pop (lane 0, command 1). A shallowest-divergence policy would instead name lane B's pop (lane 1, command 0), so this history distinguishes the two.
        let lanes = [[push(1), popReturning(2)], [popReturning(1)]]
        let (linearizable, witness) = verdict(check(lanes: lanes, finalState: []))
        #expect(linearizable == false)
        #expect(witness?.lane == 0)
        #expect(witness?.command == 1)
    }

    @Test("Pops that skip on an empty stack in both lanes are linearizable")
    func symmetricSkipsAreLinearizable() {
        // Both lanes pop an empty stack, so both skip. The replay also skips both, the final state stays empty, and the run is linearizable. This exercises the path where an observed skip matches a replayed skip.
        let lanes = [[popSkipped()], [popSkipped()]]
        #expect(verdict(check(lanes: lanes, finalState: [])).linearizable)
    }

    @Test("A prefix runs before the lanes and is respected")
    func prefixRunsBeforeConcurrentCommands() {
        // The prefix pushes 1 before the lanes start, so lane A's pop sees it and returns 1, while lane B pushes 2. The order prefix, pop→1, push(2) leaves [2], which the checker accepts.
        let lanes = [[popReturning(1)], [push(2)]]
        #expect(verdict(check(lanes: lanes, prefix: [.push(1)], finalState: [2])).linearizable)
    }

    // MARK: - Real-Time Order

    @Test("A stale observation after a completed command is rejected when timestamps prove the order")
    func staleObservationIsRejectedWithTimestamps() {
        // Lane A's push returned (at 10) before lane B's pop was even called (at 20), so real time forces push before pop, and the pop must see the pushed value. The observed skip (empty stack) is only explainable by running the pop first, which the timestamps forbid. This is the stale-read signature: without intervals the checker accepts it (see the companion test below).
        let lanes = [
            [push(1, from: 0, to: 10)],
            [popSkipped(from: 20, to: 30)],
        ]
        let (linearizable, witness) = verdict(check(lanes: lanes, finalState: [1]))
        #expect(linearizable == false)
        #expect(witness?.lane == 1)
        #expect(witness?.command == 0)
    }

    @Test("The same stale observation is accepted without timestamps")
    func staleObservationIsAcceptedWithoutTimestamps() {
        // Identical history to the test above, minus the intervals. With no timing data every command is treated as overlapping everything, so the ordering (pop on empty, then push) is a valid witness. This documents the fallback behavior for interval-free histories, and why the runners always record intervals.
        let lanes = [[push(1)], [popSkipped()]]
        #expect(verdict(check(lanes: lanes, finalState: [1])).linearizable)
    }

    @Test("Overlapping intervals leave both orders available")
    func overlappingIntervalsAcceptBothOrders() {
        // The two pushes overlap in real time (neither returned before the other was called), so both orders remain valid witnesses, exactly as in the interval-free case.
        let lanes = [
            [push(1, from: 0, to: 20)],
            [push(2, from: 10, to: 30)],
        ]
        #expect(verdict(check(lanes: lanes, finalState: [1, 2])).linearizable)
        #expect(verdict(check(lanes: lanes, finalState: [2, 1])).linearizable)
    }

    @Test("Non-overlapping intervals force the real-time order")
    func nonOverlappingIntervalsForceOrder() {
        // Lane A's push returned before lane B's push was called, so only the order (1, 2) is a candidate. The final state [2, 1] would require inverting real-time precedence and must be rejected even though it is a valid interleaving of the lane orders.
        let lanes = [
            [push(1, from: 0, to: 10)],
            [push(2, from: 20, to: 30)],
        ]
        #expect(verdict(check(lanes: lanes, finalState: [1, 2])).linearizable)
        #expect(verdict(check(lanes: lanes, finalState: [2, 1])).linearizable == false)
    }

    @Test("Real-time edges constrain commands beyond lane heads")
    func realTimeEdgesConstrainLaterLaneCommands() {
        // Lane A: push(1) then push(2), with a gap during which lane B's push(3) ran to completion. Real time pins the order to 1, 3, 2: push(3) returned before push(2) was called, and push(1) returned before push(3) was called. The other interleavings of the lane orders ([1, 2, 3] and [3, 1, 2]) invert a proven edge and must be rejected.
        let lanes = [
            [push(1, from: 0, to: 10), push(2, from: 40, to: 50)],
            [push(3, from: 20, to: 30)],
        ]
        #expect(verdict(check(lanes: lanes, finalState: [1, 3, 2])).linearizable)
        #expect(verdict(check(lanes: lanes, finalState: [1, 2, 3])).linearizable == false)
        #expect(verdict(check(lanes: lanes, finalState: [3, 1, 2])).linearizable == false)
    }

    // MARK: - Prefix Cache Regression

    @Test("Cache does not prune the valid ordering when void commands share the same cursor state")
    func cachePrefixHashDistinguishesOrderingsAtSameCursorState() {
        // Regression for the identical-observation-hash false negative.
        //
        // Lane A: enqueue(1), enqueue(2)     Lane B: enqueue(3)
        // Final state: [3, 1, 2] = ordering B[0], A[0], A[1]
        //
        // The DFS tries lane 0 (A) first at each depth:
        //   depth 0: A[0]
        //     depth 1: A[1] → depth 2: B[0] → [1,2,3] ≠ [3,1,2] → oracle fails
        //     depth 1: B[0] → cursor (A=1, B=1)
        //       depth 2: A[1] → [1,3,2] ≠ [3,1,2] → oracle fails
        //     subtree at cursor (A=1, B=1) exhausted → CACHED
        //   depth 0: B[0]
        //     depth 1: A[0] → cursor (A=1, B=1) — same cursor state
        //     cache lookup: must MISS (different prefix ordering)
        //       depth 2: A[1] → [3,1,2] = [3,1,2] → oracle PASSES
        //
        // The old cache keyed on observation hashes, which are identical for void
        // enqueue commands after value minimization. That made the prefix hash
        // order-invariant (XOR of identical per-depth contributions), so both
        // paths to cursor (A=1, B=1) shared the same cache key. The first path's
        // "no valid completion" entry pruned the second path, missing the valid
        // ordering.
        //
        // The fix keys on command identity (laneIndex, commandIndex), which is
        // unique per command regardless of observation hash. Two orderings of
        // distinct commands produce different prefix hashes.
        let laneA: [QueueObservation] = [enqueue(1), enqueue(2)]
        let laneB: [QueueObservation] = [enqueue(3)]
        let result = queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [3, 1, 2]))
        #expect(result.linearizable)
    }

    @Test("Cache does not prune valid orderings with three lanes")
    func cachePrefixHashWorksWithThreeLanes() {
        // Three lanes of void enqueues. The DFS explores lane 0 first, then
        // lane 1, then lane 2. Only the ordering C[0], A[0], B[0] produces
        // final state [3, 1, 2]. The cache must not prune it after exhausting
        // A-first and B-first subtrees that reach the same cursor state.
        let laneA: [QueueObservation] = [enqueue(1)]
        let laneB: [QueueObservation] = [enqueue(2)]
        let laneC: [QueueObservation] = [enqueue(3)]
        let result = queueVerdict(checkQueue(lanes: [laneA, laneB, laneC], finalState: [3, 1, 2]))
        #expect(result.linearizable)
    }

    @Test("Genuinely non-linearizable lost enqueue is preserved with caching")
    func genuinelyNonLinearizablePreservedWithCache() {
        // Two enqueues, but the final state shows three items. No ordering of
        // two enqueues can produce three items. The cache must not introduce
        // a false positive (claiming linearizable when it is not).
        let laneA: [QueueObservation] = [enqueue(1)]
        let laneB: [QueueObservation] = [enqueue(2)]
        let result = queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [1, 2, 3]))
        #expect(result.linearizable == false)
    }

    @Test("Cache preserves not-linearizable verdict for wrong queue ordering")
    func cachePreservesWrongOrderingVerdict() {
        // Lane A: enqueue(1), enqueue(2)   Lane B: enqueue(3)
        // Final state: [2, 1, 3] — no valid ordering produces this because
        // A[0] must precede A[1] (per-lane order), so 1 always appears before 2.
        let laneA: [QueueObservation] = [enqueue(1), enqueue(2)]
        let laneB: [QueueObservation] = [enqueue(3)]
        let result = queueVerdict(checkQueue(lanes: [laneA, laneB], finalState: [2, 1, 3]))
        #expect(result.linearizable == false)
    }
}

// MARK: - Supporting Types

/// A command on the stack model. `pop` returns the last pushed value, or skips when the stack is empty.
private enum StackCommand: CustomStringConvertible {
    case push(Int)
    case pop

    var description: String {
        switch self {
            case let .push(value):
                return "push(\(value))"
            case .pop:
                return "pop"
        }
    }
}

/// A last-in-first-out stack used as the sequential model the checker replays against.
private final class Stack {
    private(set) var elements: [Int] = []

    /// Runs a command for the prefix replay, where return values are not compared.
    func apply(_ command: StackCommand) {
        switch command {
            case let .push(value):
                elements.append(value)
            case .pop:
                if elements.isEmpty == false {
                    elements.removeLast()
                }
        }
    }

    /// Runs a command and reports what it returned, so the checker can compare it against the observed value.
    func replay(_ command: StackCommand) -> LinearizabilityChecker.ReplayResponse {
        switch command {
            case let .push(value):
                elements.append(value)
                return .init(returnValue: nil, isSkipped: false)
            case .pop:
                guard elements.isEmpty == false else {
                    return .init(returnValue: nil, isSkipped: true)
                }
                return .init(returnValue: elements.removeLast(), isSkipped: false)
        }
    }
}

// MARK: - Helpers

private typealias Observation = ObservedResponse<StackCommand>

/// Runs the checker over hand-built lane observations, replaying against a fresh stack and comparing the replayed final state to `finalState`. The checker stores outcomes only, so the replay closure maps `(laneIndex, commandIndex)` back to the observed command.
private func check(
    lanes: [[Observation]],
    prefix: [StackCommand] = [],
    finalState: [Int]
) -> LinearizabilityChecker.Result {
    let checker = LinearizabilityChecker(laneResponses: lanes)
    var replayStack: Stack?
    return checker.check(
        replayPrefix: {
            let fresh = Stack()
            for command in prefix {
                fresh.apply(command)
            }
            replayStack = fresh
            return true
        },
        replayCommand: { laneIndex, commandIndex in
            replayStack?.replay(lanes[laneIndex][commandIndex].command)
        },
        checkOracle: {
            replayStack?.elements == finalState
        },
        failureDescription: { nil }
    )
}

/// Flattens a checker result into a plain pair for assertions: whether the run was linearizable, and the witness coordinates when it was not.
private func verdict(
    _ result: LinearizabilityChecker.Result
) -> (linearizable: Bool, witness: (lane: Int, command: Int)?) {
    switch result {
        case .linearizable:
            return (true, nil)
        case let .notLinearizable(witness, _):
            return (false, witness.map { ($0.laneIndex, $0.commandIndex) })
    }
}

private func push(_ value: Int) -> Observation {
    Observation(lane: 0, command: .push(value), outcome: .returnedVoid)
}

private func push(_ value: Int, from callTime: UInt64, to returnTime: UInt64) -> Observation {
    Observation(lane: 0, command: .push(value), outcome: .returnedVoid, interval: ObservedInterval(callTime: callTime, returnTime: returnTime))
}

private func popReturning(_ value: Int) -> Observation {
    Observation(lane: 0, command: .pop, outcome: .returned(value))
}

private func popSkipped() -> Observation {
    Observation(lane: 0, command: .pop, outcome: .skipped)
}

private func popSkipped(from callTime: UInt64, to returnTime: UInt64) -> Observation {
    Observation(lane: 0, command: .pop, outcome: .skipped, interval: ObservedInterval(callTime: callTime, returnTime: returnTime))
}

// MARK: - Queue Model

private enum QueueCommand: CustomStringConvertible {
    case enqueue(Int)
    case dequeue

    var description: String {
        switch self {
            case let .enqueue(value): "enqueue(\(value))"
            case .dequeue: "dequeue"
        }
    }
}

private final class Queue {
    private(set) var elements: [Int] = []

    func apply(_ command: QueueCommand) {
        switch command {
            case let .enqueue(value):
                elements.append(value)
            case .dequeue:
                if elements.isEmpty == false {
                    elements.removeFirst()
                }
        }
    }

    func replay(_ command: QueueCommand) -> LinearizabilityChecker.ReplayResponse {
        switch command {
            case let .enqueue(value):
                elements.append(value)
                return .init(returnValue: nil, isSkipped: false)
            case .dequeue:
                if elements.isEmpty {
                    return .init(returnValue: "nil", isSkipped: false)
                }
                return .init(returnValue: elements.removeFirst(), isSkipped: false)
        }
    }
}

private typealias QueueObservation = ObservedResponse<QueueCommand>

private func checkQueue(
    lanes: [[QueueObservation]],
    prefix: [QueueCommand] = [],
    finalState: [Int]
) -> LinearizabilityChecker.Result {
    let checker = LinearizabilityChecker(laneResponses: lanes)
    var replayQueue: Queue?
    return checker.check(
        replayPrefix: {
            let fresh = Queue()
            for command in prefix {
                fresh.apply(command)
            }
            replayQueue = fresh
            return true
        },
        replayCommand: { laneIndex, commandIndex in
            replayQueue?.replay(lanes[laneIndex][commandIndex].command)
        },
        checkOracle: {
            replayQueue?.elements == finalState
        },
        failureDescription: { nil }
    )
}

private func queueVerdict(
    _ result: LinearizabilityChecker.Result
) -> (linearizable: Bool, witness: (lane: Int, command: Int)?) {
    switch result {
        case .linearizable:
            return (true, nil)
        case let .notLinearizable(witness, _):
            return (false, witness.map { ($0.laneIndex, $0.commandIndex) })
    }
}

private func enqueue(_ value: Int) -> QueueObservation {
    QueueObservation(lane: 0, command: .enqueue(value), outcome: .returnedVoid)
}

private func dequeueReturningNil() -> QueueObservation {
    QueueObservation(lane: 0, command: .dequeue, outcome: .returned("nil"))
}
