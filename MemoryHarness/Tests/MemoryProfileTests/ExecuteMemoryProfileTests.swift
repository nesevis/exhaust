import Exhaust
import Testing

@Suite(
    "State-machine memory profile",
    .serialized,
    .exhaust(.budget(.extensive))
)
struct ExecuteMemoryProfileTests {
    @Test("Extensive sequential state-machine run remains stable")
    func extensiveSequentialStateMachineRunRemainsStable() async {
        var report: ExhaustReport?
        let counterexample = await #execute(
            MemoryProfileStoreSpec.self,
            .commandLimit(64),
            .replay(19871),
            .suppress(.all),
            .onReport { report = $0 }
        )

        #expect(counterexample == nil)
        #expect(report?.randomSamplingInvocations == ExhaustBudget.extensive.samplingBudget)
    }
}

@StateMachine(.sequential)
final class MemoryProfileStoreSpec {
    var expected: [Int: String] = [:]
    @SystemUnderTest var actual: [Int: String] = [:]

    @Invariant
    func contentsMatch() -> Bool {
        actual == expected
    }

    @Command(weight: 4, .int(in: 0 ... 31), .asciiString(length: 0 ... 128))
    func update(key: Int, value: String) throws {
        expected[key] = value
        actual[key] = value
    }

    @Command(weight: 2, .int(in: 0 ... 31))
    func remove(key: Int) throws {
        expected.removeValue(forKey: key)
        actual.removeValue(forKey: key)
    }

    @Command(weight: 2, .int(in: 0 ... 31))
    func read(key: Int) throws {
        try check(actual[key] == expected[key], "stored values must match")
    }

    @Command(weight: 1)
    func clear() throws {
        expected.removeAll(keepingCapacity: true)
        actual.removeAll(keepingCapacity: true)
    }

    func failureDescription() -> String? {
        "expected: \(expected), actual: \(actual)"
    }
}
