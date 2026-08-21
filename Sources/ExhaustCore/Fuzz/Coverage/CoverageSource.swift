/// Supplies per-attempt coverage signatures to the fuzz loop.
///
/// The production conformance (``SancovCoverageSource``) reads the process-global SanitizerCoverage counter region. The synthetic test conformance computes a signature as a pure function of the generated value, which makes the entire search loop deterministic and runnable in an uninstrumented suite — corpus acceptance, plateau detection, and cluster taxonomy are all tested through this seam.
///
/// Usage per attempt: `beginAttempt()`, optionally `noteValue(_:)` when ``wantsValues`` is true, evaluate the property, then ``forEachHitEdge(_:)``. The bracket discipline matters for the sancov conformance because the counters are process-global; the runner is single-threaded, so at most one bracketed evaluation is ever open, and nothing the runner controls executes instrumented code outside it.
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

    /// Whether the source harvests comparison operands from the attempt. When false, the runner skips the capture bracket and ``forEachComparisonOperand(_:)`` entirely, and the operand-injection experiment has no pool to draw from.
    var wantsComparisons: Bool { get }

    /// Starts recording comparison operands. Called immediately before the property evaluation, so the harvest excludes the generator's own instrumented comparisons — the framework is compiled with the same flags as the system under test, and its loop and bounds comparisons would otherwise flood the pool.
    func beginComparisonCapture()

    /// Stops recording comparison operands. Called immediately after the property evaluation.
    func endComparisonCapture()

    /// Visits each comparison record — call site and both operands — captured between ``beginComparisonCapture()`` and ``endComparisonCapture()``. Only meaningful when ``wantsComparisons`` is true.
    func forEachComparisonRecord(_ body: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void)
}

package extension CoverageSource {
    var wantsValues: Bool {
        false
    }

    func noteValue(_: Any) {}

    var wantsComparisons: Bool {
        false
    }

    func beginComparisonCapture() {}

    func endComparisonCapture() {}

    func forEachComparisonRecord(_: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void) {}

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
    // @unchecked: the stored regions are immutable after init, and the counter bytes they point at are only read and zeroed on the runner's single lane, inside the attempt bracket.
    private let regions: [SancovRuntime.CounterRegion]

    /// The total instrumented edge count across all regions.
    package let edgeCount: Int

    /// Whether this source drains comparison operands each attempt. Set at init from the experiment knob and the hooks' presence, so the per-attempt path pays nothing when the channel is off or the build lacks `trace-cmp`.
    package let wantsComparisons: Bool

    /// Creates a source over the currently registered counter regions, or returns nil when no instrumented image registered — the caller surfaces the missing-instrumentation diagnostic.
    ///
    /// - Parameter harvestsComparisons: Requests comparison-operand harvesting. On a build without the `trace-cmp` flag the hooks never fire, so the buffer stays empty and every drain is a cheap no-op — the channel is safe to request unconditionally and costs nothing when the instrumentation is absent.
    package init?(harvestsComparisons: Bool = false) {
        let regions = SancovRuntime.currentCounterRegions()
        guard regions.isEmpty == false else {
            return nil
        }
        self.regions = regions
        edgeCount = regions.reduce(0) { $0 + $1.count }
        wantsComparisons = harvestsComparisons
    }

    package func beginAttempt() {
        for region in regions {
            region.base.update(repeating: 0, count: region.count)
        }
        if wantsComparisons {
            ComparisonRuntime.reset()
        }
    }

    package func beginComparisonCapture() {
        ComparisonRuntime.setEnabled(true)
    }

    package func endComparisonCapture() {
        ComparisonRuntime.setEnabled(false)
    }

    package func forEachComparisonRecord(_ body: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void) {
        guard wantsComparisons else {
            return
        }
        ComparisonRuntime.forEachRecord(body)
    }

    /// Reports every nonzero counter, scanning eight bytes at a time.
    ///
    /// A typical attempt lights a low single-digit percentage of the instrumented edges, so almost every eight-byte window is entirely zero and can be rejected with one load and one compare instead of eight. The byte loop survives for the unaligned head and tail, so the reported edges are identical either way.
    package func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        for region in regions {
            var index = 0
            // Head: bytes before the first eight-byte boundary.
            let alignment = Int(UInt(bitPattern: region.base) % 8)
            let headCount = alignment == 0 ? 0 : min(8 - alignment, region.count)
            while index < headCount {
                let hitCount = region.base[index]
                if hitCount != 0 {
                    body(region.globalOffset + index, hitCount)
                }
                index += 1
            }
            // Body: whole words, skipped entirely when no counter in the window fired.
            let wordEnd = index + (region.count - index) / 8 * 8
            while index < wordEnd {
                let word = UnsafeRawPointer(region.base + index).loadUnaligned(as: UInt64.self)
                if word != 0 {
                    for offset in 0 ..< 8 {
                        let hitCount = region.base[index + offset]
                        if hitCount != 0 {
                            body(region.globalOffset + index + offset, hitCount)
                        }
                    }
                }
                index += 8
            }
            // Tail: whatever the word loop could not cover.
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
