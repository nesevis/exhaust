import Exhaust
import Testing

@Suite("Actor contract tests", .serialized, .tags(.contract))
struct ActorContractTests {
    @Test("Sequential actor contract passes when model and SUT agree")
    func passingActorContract() async {
        let result = await #execute(
            ActorCounterContract.self,
            .commandLimit(10),
            .budget(.custom(coverage: 50, sampling: 50)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Actor counter contract should pass")
    }

    @Test("Sequential actor contract finds invariant violation")
    func failingActorContract() async {
        let result = await #execute(
            BuggyActorCounterContract.self,
            .commandLimit(10),
            .budget(.custom(coverage: 50, sampling: 100)),
            .suppress(.issueReporting)
        )
        #expect(result != nil, "Buggy actor counter should fail")
    }
}

// MARK: - Passing Actor Contract

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

@Contract(.sequential)
actor ActorCounterContract {
    @Model var expected: Int = 0
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
}

// MARK: - Failing Actor Contract

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

@Contract(.sequential)
actor BuggyActorCounterContract {
    @Model var expected: Int = 0
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
}
