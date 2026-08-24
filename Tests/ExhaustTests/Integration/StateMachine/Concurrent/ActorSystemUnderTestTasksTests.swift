import ExhaustCore
import Testing
@testable import Exhaust

// An actor as the @SystemUnderTest under mode: .tasks. The mechanism this rests on is task executor preference (SE-0417): a default actor executes its isolated code on the calling task's preferred executor, so a lane's hop into the actor stays on the drain thread, continuations keep flowing through the run queue, and every suspension inside an actor method is an interleaving point the scheduler controls. The bug class that makes this worth having is actor reentrancy: an actor method that suspends between a check and the act it guards admits another lane at the suspension, and the check's snapshot goes stale.
//
// The deterministic tests call `drainSchedule` directly so a lost continuation shows up as `timedOut` rather than as flakiness: if the actor's executor ever took the work away from the drain loop, the continuation would never come back and the drain would stall. Custom-executor actors do exactly that and stay unsupported; these tests cover default actors only.

@Suite("Actor system under test on the task-based runner", .serialized, .tags(.stateMachine))
struct ActorSystemUnderTestTasksTests {
    /// The schedule interleaves two withdrawals inside each other's check-then-act window: lane A checks and suspends, lane B checks the same stale balance and suspends, then both deduct. The invariant catches the negative balance at quiescence. `timedOut` staying false is the half of the assertion that verifies the mechanism: every continuation the actor produced came back to the drain loop.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A reentrancy bug in an actor SUT is caught by a deterministic schedule")
    func reentrancyBugIsCaughtByDeterministicSchedule() {
        let commands: [(ScheduleMarker, ReentrantBudgetSpec.Command)] = [
            (ScheduleMarker(rawValue: 0), .deposit),
            (ScheduleMarker(rawValue: 1), .withdraw),
            (ScheduleMarker(rawValue: 2), .withdraw),
        ]
        let result = drainSchedule(
            taggedCommands: commands,
            setupStep: nil,
            specInit: { ReentrantBudgetSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )
        #expect(result.timedOut == false, "The drain loop lost a continuation to the actor's executor")
        #expect(result.passed == false, "Two overlapping withdrawals drove the balance negative and the invariant should see it")
    }

    /// The same schedule against an actor whose withdrawal is synchronous, so the check and the act share one isolated step and no suspension separates them. Passing here pins down that the failure above is the reentrancy window, not the actor hop.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("A correct actor SUT passes the same schedule without stalling the drain")
    func correctActorPassesTheSameSchedule() {
        let commands: [(ScheduleMarker, AtomicBudgetSpec.Command)] = [
            (ScheduleMarker(rawValue: 0), .deposit),
            (ScheduleMarker(rawValue: 1), .withdraw),
            (ScheduleMarker(rawValue: 2), .withdraw),
        ]
        let result = drainSchedule(
            taggedCommands: commands,
            setupStep: nil,
            specInit: { AtomicBudgetSpec() },
            concurrencyLevel: 2,
            recordTrace: true
        )
        #expect(result.timedOut == false, "The drain loop lost a continuation to the actor's executor")
        #expect(result.passed == true, "An atomic check-then-act has no reentrancy window and nothing else is wrong")
    }

    /// The full pipeline finds the reentrancy bug on its own: generation supplies the schedules, and any interleaving of two withdrawals around one deposit reaches the window.
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("The pipeline discovers an actor reentrancy bug under mode: .tasks")
    func pipelineDiscoversActorReentrancyBug() async throws {
        let result = await #execute(
            ReentrantBudgetSpec.self,
            mode: .tasks,
            .commandLimit(6),
            .budget(.custom(screening: 100, sampling: 400)),
            .suppress(.all)
        )
        _ = try #require(result, "A reentrant withdraw loses its balance check under interleaving and should be found")
    }
}

// MARK: - Specs

/// Invariant-only spec: the budget's one promise is that its balance never goes negative, which is exactly what a stale check-then-act breaks.
@StateMachine
final class ReentrantBudgetSpec {
    @SystemUnderTest
    var budget: ReentrantBudget = .init()

    @Invariant
    func balanceNeverNegative() async -> Bool {
        let balance = await budget.currentBalance
        return balance >= 0
    }

    @Command(weight: 1)
    func deposit() async throws {
        await budget.deposit(1)
    }

    @Command(weight: 2)
    func withdraw() async throws {
        _ = await budget.withdraw(1)
    }

    func failureDescription() -> String? {
        nil
    }
}

/// ``ReentrantBudgetSpec`` pointed at the actor without the reentrancy window.
@StateMachine
final class AtomicBudgetSpec {
    @SystemUnderTest
    var budget: AtomicBudget = .init()

    @Invariant
    func balanceNeverNegative() async -> Bool {
        let balance = await budget.currentBalance
        return balance >= 0
    }

    @Command(weight: 1)
    func deposit() async throws {
        await budget.deposit(1)
    }

    @Command(weight: 2)
    func withdraw() async throws {
        _ = await budget.withdraw(1)
    }

    func failureDescription() -> String? {
        nil
    }
}

// MARK: - Supporting Types

/// A budget actor with the classic reentrancy bug: `withdraw` checks the balance, suspends, and then deducts against the checked snapshot. Another withdrawal entering at the suspension sees the same balance, both checks pass, and the balance goes negative.
actor ReentrantBudget {
    private var balance: Int = 0

    var currentBalance: Int {
        balance
    }

    func deposit(_ amount: Int) {
        balance += amount
    }

    func withdraw(_ amount: Int) async -> Bool {
        guard balance >= amount else {
            return false
        }
        // The reentrancy window: the guard's snapshot is stale by the time the deduction runs.
        await Task.yield()
        balance -= amount
        return true
    }
}

/// The correct counterpart: the check and the deduction share one synchronous isolated step, so no other caller can interleave between them.
actor AtomicBudget {
    private var balance: Int = 0

    var currentBalance: Int {
        balance
    }

    func deposit(_ amount: Int) {
        balance += amount
    }

    func withdraw(_ amount: Int) -> Bool {
        guard balance >= amount else {
            return false
        }
        balance -= amount
        return true
    }
}
