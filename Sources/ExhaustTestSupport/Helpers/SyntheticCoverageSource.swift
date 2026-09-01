// Test-only CoverageSource computing signatures as a pure function of the generated value.

import ExhaustCore
import Foundation

/// A ``CoverageSource`` whose signature is a deterministic function of the generated value, requiring no instrumentation.
///
/// Lets the entire fuzz search loop (corpus acceptance, bucketing, rarity decay, tier stratification, plateau detection, cluster taxonomy) run deterministically in the ordinary uninstrumented test suite. The signature function models the SUT's branch behavior: values that "reach the same branches" map to overlapping edge sets.
public final class SyntheticCoverageSource<Value>: CoverageSource, @unchecked Sendable {
    // @unchecked: the stashed value is written and read only inside the runner's per-attempt bracket. The lock covers concurrent bracket use from tests that simulate reduction re-runs.
    public let edgeCount: Int

    public var wantsValues: Bool {
        true
    }

    /// Whether the source claims to be live instrumentation, so the runner's unreachable-coverage check applies to it. False by default: a synthetic edge function may map every value to no edges on purpose.
    public let reportsLiveCoverage: Bool

    private let hitEdges: @Sendable (Value) -> [(edge: Int, hitCount: UInt8)]
    private let comparisons: (@Sendable (Value) -> [(site: UInt64, lhs: UInt64, rhs: UInt64)])?
    private let lock = NSLock()
    private var currentValue: Value?

    public var wantsComparisons: Bool {
        comparisons != nil
    }

    /// Creates a source reporting the exact (edge, hit count) pairs returned by `hitEdges`, and optionally the comparison records returned by `comparisons` — a deterministic model of the trace-cmp operand harvest, for testing operand injection without instrumentation.
    public init(
        edgeCount: Int,
        reportsLiveCoverage: Bool = false,
        hitEdges: @escaping @Sendable (Value) -> [(edge: Int, hitCount: UInt8)],
        comparisons: (@Sendable (Value) -> [(site: UInt64, lhs: UInt64, rhs: UInt64)])? = nil
    ) {
        self.edgeCount = edgeCount
        self.reportsLiveCoverage = reportsLiveCoverage
        self.hitEdges = hitEdges
        self.comparisons = comparisons
    }

    /// Creates a source where every reported edge has hit count 1, from a plain edge-set function.
    public convenience init(
        edgeCount: Int,
        reportsLiveCoverage: Bool = false,
        edges: @escaping @Sendable (Value) -> [Int],
        comparisons: (@Sendable (Value) -> [(site: UInt64, lhs: UInt64, rhs: UInt64)])? = nil
    ) {
        self.init(
            edgeCount: edgeCount,
            reportsLiveCoverage: reportsLiveCoverage,
            hitEdges: { value in edges(value).map { (edge: $0, hitCount: 1) } },
            comparisons: comparisons
        )
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

    public func forEachComparisonRecord(_ body: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void) {
        lock.lock()
        let value = currentValue
        lock.unlock()
        guard let value, let comparisons else {
            return
        }
        for record in comparisons(value) {
            body(record.site, record.lhs, record.rhs)
        }
    }
}
