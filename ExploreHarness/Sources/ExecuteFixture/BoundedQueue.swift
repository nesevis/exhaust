// A deliberately buggy bounded queue for the execute-time harness.
//
// Default capacity 24 (SW2a sweep: {16, 24, 32}). Six commands. Fault A is the swarm
// target: its differential lives in reset absence, not coverage guidance. No edge
// correlates with highWaterMark, so branch coverage offers no gradient toward A. The
// one fill-correlated branch is the capacity guard in `enqueue`, which tracks `count`;
// `dequeue` decouples `count` from `highWaterMark`, and on the pure-accumulation path A
// fires before that guard is ever reached, so it forms no usable ladder toward A.
// `isFull` exposes the same guard predicate and is intentionally left uncalled.
//
// ## Shape Coordinates
//
// Trigger class: accumulation/absence (A) plus a sequence-gated shared-symptom pair (S, P). Coverage surface: flat on every trigger (no edge correlates with any trigger variable's progress). Vocabulary: six commands, uniform weight. Argument domains: small ints (0...9, 1...3). Length scale: fault A's minimal is 24 commands at the default capacity — inside the default limit of 40; S and P are far inside.
//
// ## Ground-Truth Registry
//
// Fault A (swarm-suppressed accumulation):
//     Trigger: highWaterMark >= capacity (enqueue/batchEnqueue additions without an
//       intervening dequeue or clear). No edge correlates with highWaterMark progress.
//     Trigger variable: highWaterMark (independent of clearWhenNonEmpty, peekAtCountOne).
//     Minimal at capacity 24: [enqueue(0)] x24.
//     Effect: corrupts elements[0] to -999.
//
// Fault S (sequence-gated, shared symptom with P):
//     Trigger: clearWhenNonEmptyCount >= 2 (clear a non-empty queue, twice in one run).
//     Trigger variable: clearWhenNonEmptyCount (independent of highWaterMark, peekAtCountOne).
//     Minimal: [enqueue(0), clear, enqueue(0), clear]
//     Effect: sets elements to [-888] (detected by model invariant).
//
// Fault P (shared symptom with S):
//     Trigger: peekAtCountOneCount >= 3 (peekTracked while queue.count == 1, three times).
//     Trigger variable: peekAtCountOneCount (independent of highWaterMark, clearWhenNonEmpty).
//     Minimal: [enqueue(0), peekTracked, peekTracked, peekTracked]
//     Effect: throws BoundedQueueError.corruption (same symptom as S via model invariant).
//
// Fault D (producer-dependent): dequeue and peekTracked skip on empty queue.
//     Not a corruption fault — measures precondition starvation under swarm.
//
// ## Trigger Disjointness
//
// A fires on highWaterMark (resets on dequeue/clear). S fires on clearWhenNonEmpty
// (requires clear, which resets hwm). P fires on peekAtCountOne (needs count==1;
// high hwm at capacity 24 implies count>=24, never 1). No trigger is a subset of another.
//
// Pinned baselines (MX1g re-measure, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): A 6/20 (earlier pin 4/20), S 20/20, P 20/20.

public struct BoundedQueue: Sendable {
    public private(set) var elements: [Int]
    public let capacity: Int

    /// Fault A trigger: counts enqueue/batchEnqueue additions without an intervening dequeue/clear.
    private var highWaterMark: Int = 0

    /// Fault S trigger variable.
    private var clearWhenNonEmptyCount: Int = 0

    /// Fault P trigger variable.
    private var peekAtCountOneCount: Int = 0

    public init(capacity: Int = 24) {
        elements = []
        self.capacity = capacity
    }

    public var count: Int {
        elements.count
    }

    public var isEmpty: Bool {
        elements.isEmpty
    }

    public var isFull: Bool {
        elements.count >= capacity
    }

    // MARK: - Commands

    public mutating func enqueue(_ value: Int) -> Bool {
        if elements.count >= capacity {
            return false
        }
        elements.append(value)
        highWaterMark += 1

        // Fault A: fires when hwm reaches capacity. The firing itself lights no new edge.
        if highWaterMark >= capacity {
            elements[0] = -999
        }

        return true
    }

    public mutating func dequeue() throws -> Int {
        guard elements.isEmpty == false else {
            throw BoundedQueueError.empty
        }
        highWaterMark = 0
        return elements.removeFirst()
    }

    public func peek() throws -> Int {
        guard elements.isEmpty == false else {
            throw BoundedQueueError.empty
        }
        return elements[0]
    }

    public mutating func peekTracked() throws -> Int {
        guard elements.isEmpty == false else {
            throw BoundedQueueError.empty
        }
        // Fault P trigger: peek while count == 1.
        if elements.count == 1 {
            peekAtCountOneCount += 1
            if peekAtCountOneCount >= 3 {
                throw BoundedQueueError.corruption
            }
        }
        return elements[0]
    }

    public mutating func clear() {
        // Fault S trigger: clear while non-empty.
        if elements.isEmpty == false {
            clearWhenNonEmptyCount += 1
            if clearWhenNonEmptyCount >= 2 {
                elements = [-888]
                return
            }
        }
        elements.removeAll()
        highWaterMark = 0
    }

    public mutating func batchEnqueue(_ values: [Int]) -> Int {
        var added = 0
        for value in values where enqueue(value) {
            added += 1
        }
        return added
    }

    public func stats() -> (count: Int, capacity: Int, hwm: Int) {
        (count: elements.count, capacity: capacity, hwm: highWaterMark)
    }
}

public enum BoundedQueueError: Error, Equatable, Sendable {
    case empty
    case corruption
}
