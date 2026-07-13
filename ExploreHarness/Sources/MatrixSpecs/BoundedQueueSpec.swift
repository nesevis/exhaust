import ExecuteFixture
import Exhaust

/// The shared spec for the `BoundedQueue` fixture (faults A, S, P, D — registry in `BoundedQueue.swift`).
///
/// Lives in `MatrixSpecs` so `ExecuteTests` and `ExploreBenchmark` measure the same spec: the class is `public`, and access-level-mirroring `@StateMachine` synthesis makes the synthesized members public with it.
@StateMachine(.sequential)
public final class BoundedQueueSpec {
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

    /// Reports the SUT and model contents at the point of failure.
    public func failureDescription() -> String? {
        "queue: \(queue.elements), model: \(model)"
    }
}
