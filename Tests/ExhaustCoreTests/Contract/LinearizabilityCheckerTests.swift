import Testing
@testable import ExhaustCore

/// Tests the linearizability checker directly, using hand-built histories and a stack model.
///
/// The checker answers one question: could the values seen during a concurrent run have come from running the commands one at a time, in some order that keeps each lane's commands in their original sequence? Commands on the same lane must stay in order; commands on different lanes may be tried in either order.
///
/// A stack makes a good model because its answers depend on order. A `pop` returns the value pushed last, or reports a skip when the stack is empty, so a wrong return value (a value that was never pushed) and a wrong final state are both easy to build. Each test supplies fixed observations and a fixed final state, so the verdict is deterministic. There are no real threads.
@Suite("Linearizability checker")
struct LinearizabilityCheckerTests {
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

    @Test("Witness points at the command reached only after the deepest matching prefix")
    func witnessPicksDeepestDivergence() {
        // Lane A's pop reports 7, a value never pushed. Lane B pushes 5 then pops 5 (both fine). The order that matches the most commands before failing is push(5), pop→5, then A's pop, which fails at the third step. The witness is that pop, the only impossible command, found via the longest matching prefix rather than an earlier, shallower mismatch.
        let lanes = [[popReturning(7)], [push(5), popReturning(5)]]
        let (linearizable, witness) = verdict(check(lanes: lanes, finalState: []))
        #expect(linearizable == false)
        #expect(witness?.lane == 0)
        #expect(witness?.command == 0)
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
    func replay(_ command: StackCommand) -> LinearizabilityChecker<StackCommand>.ReplayResponse {
        switch command {
            case let .push(value):
                elements.append(value)
                return .init(commandDescription: command.description, returnValue: nil, isSkipped: false)
            case .pop:
                guard elements.isEmpty == false else {
                    return .init(commandDescription: command.description, returnValue: nil, isSkipped: true)
                }
                return .init(commandDescription: command.description, returnValue: elements.removeLast(), isSkipped: false)
        }
    }
}

// MARK: - Helpers

private typealias Observation = LinearizabilityChecker<StackCommand>.Observation

/// Runs the checker over hand-built lane observations, replaying against a fresh stack and comparing the replayed final state to `finalState`.
private func check(
    lanes: [[Observation]],
    prefix: [StackCommand] = [],
    finalState: [Int]
) -> LinearizabilityChecker<StackCommand>.Result {
    let checker = LinearizabilityChecker(laneObservations: lanes)
    var replayStack: Stack?
    return checker.check(
        prefix: prefix,
        replayPrefix: { prefixCommands in
            let fresh = Stack()
            for command in prefixCommands {
                fresh.apply(command)
            }
            replayStack = fresh
            return true
        },
        replayCommand: { command in
            replayStack?.replay(command)
        },
        checkOracle: {
            replayStack?.elements == finalState
        }
    )
}

/// Flattens a checker result into a plain pair for assertions: whether the run was linearizable, and the witness coordinates when it was not.
private func verdict(
    _ result: LinearizabilityChecker<StackCommand>.Result
) -> (linearizable: Bool, witness: (lane: Int, command: Int)?) {
    switch result {
        case .linearizable:
            return (true, nil)
        case let .notLinearizable(witness):
            return (false, witness.map { ($0.laneIndex, $0.commandIndex) })
    }
}

private func push(_ value: Int) -> Observation {
    Observation(command: .push(value), commandDescription: "push(\(value))", returnValue: nil, isSkipped: false)
}

private func popReturning(_ value: Int) -> Observation {
    Observation(command: .pop, commandDescription: "pop", returnValue: value, isSkipped: false)
}

private func popSkipped() -> Observation {
    Observation(command: .pop, commandDescription: "pop", returnValue: nil, isSkipped: true)
}
