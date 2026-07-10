import Exhaust
import Testing

@Suite("Actor spec tests", .serialized, .tags(.stateMachine))
struct ActorStateMachineTests {
    @Test("Sequential actor spec passes when model and SUT agree")
    func passingActorSpec() async {
        let result = await #execute(
            ActorCounterSpec.self,
            .commandLimit(10),
            .budget(.custom(screening: 50, sampling: 50)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Actor counter spec should pass")
    }

    @Test("Sequential actor spec finds invariant violation")
    func failingActorSpec() async {
        let result = await #execute(
            BuggyActorCounterSpec.self,
            .commandLimit(10),
            .budget(.custom(screening: 50, sampling: 100)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "Buggy actor counter should fail")
    }
}

// MARK: - Passing Actor StateMachine

actor CounterActor {
    var value: Int = 0

    func increment() {
        value += 1
    }

    func decrement() {
        value -= 1
    }

    func read() -> Int {
        value
    }
}

@StateMachine(.sequential)
actor ActorCounterSpec {
    var expected: Int = 0
    @SystemUnderTest var counter = CounterActor()

    @Invariant
    func valueMatches() async -> Bool {
        await counter.read() == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        expected -= 1
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}

// MARK: - Failing Actor StateMachine

actor BuggyCounterActor {
    var value: Int = 0

    func increment() {
        value += 1
    }

    func decrement() {
        // Bug: decrement is a no-op
    }

    func read() -> Int {
        value
    }
}

@StateMachine(.sequential)
actor BuggyActorCounterSpec {
    var expected: Int = 0
    @SystemUnderTest var counter = BuggyCounterActor()

    @Invariant
    func valueMatches() async -> Bool {
        await counter.read() == expected
    }

    @Command(weight: 3)
    func increment() async throws {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        expected -= 1
        await counter.decrement()
    }

    func failureDescription() -> String? {
        "\(counter)"
    }
}
