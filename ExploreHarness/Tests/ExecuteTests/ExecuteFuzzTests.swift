import ExecuteFixture
import Exhaust
import ExhaustCore
import Testing

@Suite("Execute fuzz validation", .serialized)
struct ExecuteFuzzTests {
    @Test("A fuzz run finds at least one fault in the bounded queue spec")
    func findsAtLeastOneFault() async {
        let report = await #execute(
            BoundedQueueSpec.self,
            time: .seconds(5),
            .commandLimit(40),
            .suppress(.issueReporting)
        )
        #expect(report.clusters.isEmpty == false)
        #expect(report.totalAttempts > 0)
    }
}

// MARK: - Spec

/// Twin of BenchmarkQueueSpec in ExploreBenchmark.swift: the benchmark must measure the same spec these tests validate, and the two targets cannot share the class because @StateMachine synthesis is module-internal. Change both or neither.
@StateMachine(.sequential)
final class BoundedQueueSpec {
    var model: [Int] = []
    @SystemUnderTest var queue: BoundedQueue = .init(capacity: 24)

    @Invariant
    func countMatchesModel() -> Bool {
        queue.count == model.count
    }

    @Invariant
    func elementsMatchModel() -> Bool {
        queue.elements == model
    }

    @Command(weight: 1, .int(in: 0 ... 9))
    func enqueue(value: Int) throws {
        let succeeded = queue.enqueue(value)
        if succeeded {
            model.append(value)
        }
    }

    @Command(weight: 1)
    func dequeue() throws {
        guard queue.isEmpty == false else {
            throw skip()
        }
        let removed = try queue.dequeue()
        let expected = model.removeFirst()
        guard removed == expected else {
            throw BoundedQueueError.corruption
        }
    }

    @Command(weight: 1)
    func peekTracked() throws {
        guard queue.isEmpty == false else {
            throw skip()
        }
        let peeked = try queue.peekTracked()
        guard peeked == model.first else {
            throw BoundedQueueError.corruption
        }
    }

    @Command(weight: 1)
    func clear() throws {
        queue.clear()
        if queue.elements == [-888] {
            throw BoundedQueueError.corruption
        }
        model.removeAll()
    }

    @Command(weight: 1, .int(in: 1 ... 3), .int(in: 0 ... 9))
    func batchEnqueue(count: Int, startValue: Int) throws {
        let values = (0 ..< count).map { startValue + $0 }
        let added = queue.batchEnqueue(values)
        model.append(contentsOf: values.prefix(added))
    }

    @Command(weight: 1)
    func stats() throws {
        let info = queue.stats()
        guard info.count == model.count else {
            throw BoundedQueueError.corruption
        }
    }

    func failureDescription() -> String? {
        "queue: \(queue.elements), model: \(model)"
    }
}
