// Test-only CoverageSource computing signatures as a pure function of the generated value.

import ExhaustCore
import Foundation

/// A ``CoverageSource`` whose signature is a deterministic function of the generated value, requiring no instrumentation.
///
/// Lets the entire fuzz search loop — corpus acceptance, bucketing, rarity decay, tier stratification, plateau detection, cluster taxonomy — run deterministically in the ordinary uninstrumented test suite. The signature function models the SUT's branch behavior: values that "reach the same branches" map to overlapping edge sets.
public final class SyntheticCoverageSource<Value>: CoverageSource, @unchecked Sendable {
    // @unchecked: the stashed value is written and read only inside the runner's per-attempt bracket. The lock covers concurrent bracket use from tests that simulate reduction re-runs.
    public let edgeCount: Int

    public var wantsValues: Bool {
        true
    }

    private let hitEdges: @Sendable (Value) -> [(edge: Int, hitCount: UInt8)]
    private let lock = NSLock()
    private var currentValue: Value?

    /// Creates a source reporting the exact (edge, hit count) pairs returned by `hitEdges`.
    public init(edgeCount: Int, hitEdges: @escaping @Sendable (Value) -> [(edge: Int, hitCount: UInt8)]) {
        self.edgeCount = edgeCount
        self.hitEdges = hitEdges
    }

    /// Creates a source where every reported edge has hit count 1, from a plain edge-set function.
    public convenience init(edgeCount: Int, edges: @escaping @Sendable (Value) -> [Int]) {
        self.init(edgeCount: edgeCount) { value in
            edges(value).map { (edge: $0, hitCount: 1) }
        }
    }

    public func beginAttempt() {
        lock.lock()
        defer { lock.unlock() }
        currentValue = nil
    }

    public func noteValue(_ value: Any) {
        guard let typed = value as? Value else {
            preconditionFailure("SyntheticCoverageSource<\(Value.self)> received a \(type(of: value))")
        }
        lock.lock()
        defer { lock.unlock() }
        currentValue = typed
    }

    public func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        lock.lock()
        let value = currentValue
        lock.unlock()
        guard let value else {
            return
        }
        for (edge, hitCount) in hitEdges(value) {
            body(edge, hitCount)
        }
    }
}
