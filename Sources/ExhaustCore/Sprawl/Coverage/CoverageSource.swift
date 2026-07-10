// The seam between the sprawl loop and coverage attribution.

/// Supplies per-attempt coverage signatures to the sprawl loop.
///
/// The production conformance (``SancovCoverageSource``) reads the process-global SanitizerCoverage counter region. The synthetic test conformance computes a signature as a pure function of the generated value, which makes the entire search loop deterministic and runnable in an uninstrumented suite — corpus acceptance, plateau detection, and cluster taxonomy are all tested through this seam.
///
/// Usage per attempt: `beginAttempt()`, optionally `noteValue(_:)` when ``wantsValues`` is true, evaluate the property, then ``forEachHitEdge(_:)``. The bracket discipline matters for the sancov conformance because the counters are process-global; the attribution token (owned by the runner, not the source) guarantees at most one bracketed evaluation at a time.
package protocol CoverageSource: AnyObject, Sendable {
    /// The number of edges this source can report; signatures produced against it use this as their ``BitSet`` capacity.
    var edgeCount: Int { get }

    /// Whether the source derives signatures from generated values rather than live counters. When false, the runner skips ``noteValue(_:)`` and its `Any` boxing on the hot path.
    var wantsValues: Bool { get }

    /// Clears attribution state ahead of one property evaluation.
    func beginAttempt()

    /// Records the value about to be evaluated. Called between ``beginAttempt()`` and the evaluation, and only when ``wantsValues`` is true.
    func noteValue(_ value: Any)

    /// Visits each edge hit during the attempt bracketed by ``beginAttempt()``, with its saturating 8-bit hit count.
    func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void)
}

package extension CoverageSource {
    var wantsValues: Bool {
        false
    }

    func noteValue(_: Any) {}

    /// The attempt's coverage signature as a ``BitSet`` of hit edges.
    func signature() -> BitSet {
        var signature = BitSet(capacity: edgeCount)
        forEachHitEdge { edge, _ in
            signature.insert(edge)
        }
        return signature
    }
}

// MARK: - Sancov-Backed Source

/// Reads per-attempt coverage from the SanitizerCoverage inline 8-bit counter regions.
///
/// Captures the registered regions once at init: registration completes during image loading, so by the time a runner constructs a source the region list is final, and the hot path reads raw pointers without locking. `beginAttempt` zeroes every counter byte; `forEachHitEdge` scans for nonzero bytes and reports them under the global edge indexing described on ``SancovRuntime``.
package final class SancovCoverageSource: CoverageSource, @unchecked Sendable {
    // @unchecked: the stored regions are immutable after init, and the counter bytes they point at are only mutated inside the attribution bracket, which the runner serialises with the attribution token.
    private let regions: [SancovRuntime.CounterRegion]

    /// The total instrumented edge count across all regions.
    package let edgeCount: Int

    /// Creates a source over the currently registered counter regions, or returns nil when no instrumented image registered — the caller surfaces the missing-instrumentation diagnostic.
    package init?() {
        let regions = SancovRuntime.currentCounterRegions()
        guard regions.isEmpty == false else {
            return nil
        }
        self.regions = regions
        edgeCount = regions.reduce(0) { $0 + $1.count }
    }

    package func beginAttempt() {
        for region in regions {
            region.base.update(repeating: 0, count: region.count)
        }
    }

    package func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        for region in regions {
            var index = 0
            while index < region.count {
                let hitCount = region.base[index]
                if hitCount != 0 {
                    body(region.globalOffset + index, hitCount)
                }
                index += 1
            }
        }
    }
}
