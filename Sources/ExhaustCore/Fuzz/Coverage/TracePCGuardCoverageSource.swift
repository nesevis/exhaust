// Isolated per-attempt coverage over SanitizerCoverage's trace-pc-guard callbacks.

// Internal for the reason ``ComparisonRuntime`` is: the C module must stay out of ExhaustCore's emitted `.swiftinterface`, so the hooks appear only in function bodies here and never in a `package` or `public` signature. The context pointer is private for the same reason.
internal import ExhaustCoverageRuntime

/// Reads per-attempt coverage from a thread-bound edge context rather than the process-global counter table.
///
/// ## Why this exists beside ``SancovCoverageSource``
///
/// `inline-8bit-counters` compiles an edge into an increment of a fixed global byte. There is no call, so there is no point at which a runtime could ask which run the hit belongs to, and no record of which counters moved. That forces two costs the counter model cannot avoid: every run in a process shares one table, and every attempt must clear and rescan the whole table because it cannot know what changed. Measured on an 89,832-edge build, the rescan alone is 17.7 µs per attempt against 0.46 µs for the clear.
///
/// `trace-pc-guard` compiles an edge into a call. The hook reads a thread-local context, so concurrent runs write to different arrays, and it appends each edge to a covered list on first hit, so reset and read are both proportional to what the attempt lit rather than to the size of the instrumented binary.
///
/// ## Why a thread key is sufficient here
///
/// A general-purpose fuzzer cannot key by thread, because a Swift task can resume on a different thread than it suspended on. Exhaust does not have that problem: the runner owns one GCD lane, and an async property's continuations are drained on that same lane by `LaneExecutor`, so the property never executes anywhere the bracket does not. Edges fired on a thread the runner did not bind are dropped rather than misattributed, which is the correct answer for module constructors and test-framework startup, and a known limitation for a system under test that runs instrumented work on its own threads.
package final class TracePCGuardCoverageSource: CoverageSource, @unchecked Sendable {
    // @unchecked: the context is created once and touched only on the runner's single lane, inside the attempt bracket.
    private let context: OpaquePointer

    /// The total instrumented edge count across all registered images.
    package let edgeCount: Int

    /// Whether this source drains comparison operands each attempt, set at init from the caller's request exactly as ``SancovCoverageSource`` does.
    package let wantsComparisons: Bool

    /// True: the guards are fired by instrumented code, so an attempt that lights none of them ran on a thread this context was not bound to.
    package var reportsLiveCoverage: Bool {
        true
    }

    /// Whether this source's context is the one bound on the calling thread, so edges fired here reach it. Test-only; production never asks, because `beginAttempt()` binds unconditionally.
    package var isBoundOnCurrentThread: Bool {
        exhaust_tpg_is_bound(context)
    }

    /// Whether any instrumented image registered guard regions. False means the build lacks `trace-pc-guard`.
    package static var isInstrumented: Bool {
        exhaust_tpg_edge_total() > 0
    }

    /// Creates a source over the registered guard regions, or returns nil when the build lacks `trace-pc-guard` instrumentation or the allocation fails.
    package init?(harvestsComparisons: Bool = false) {
        let total = exhaust_tpg_edge_total()
        guard total > 0, let context = exhaust_tpg_create() else {
            return nil
        }
        self.context = context
        edgeCount = Int(total)
        wantsComparisons = harvestsComparisons
    }

    deinit {
        exhaust_tpg_destroy(context)
    }

    package func beginAttempt() {
        // Binding here rather than at init keeps the thread key correct without assuming which thread constructed the source: `beginAttempt` always runs on the lane that owns the run.
        exhaust_tpg_bind(context)
        exhaust_tpg_reset(context)
        if wantsComparisons {
            ComparisonRuntime.reset()
        }
    }

    /// Visits the edges this attempt lit, in first-hit order.
    ///
    /// Guard ids are 1-based, because zero marks an unassigned guard in the init callback. Edge indices are reported 0-based to match ``SancovCoverageSource``, so a signature means the same thing whichever source produced it within one build.
    package func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        let count = exhaust_tpg_covered_count(context)
        guard count > 0, let covered = exhaust_tpg_covered(context) else {
            return
        }
        for index in 0 ..< count {
            let edge = covered[index]
            body(Int(edge) - 1, exhaust_tpg_hit_count(context, edge))
        }
    }

    // MARK: - Test Support

    /// Registers `count` synthetic guards as one image would, returning the guard array so a test can fire them through ``fireGuardForTesting(_:)``. The registry is process-global; pair with ``resetRegistryForTesting()``.
    package static func registerGuardsForTesting(count: Int) -> UnsafeMutablePointer<UInt32> {
        let guards = UnsafeMutablePointer<UInt32>.allocate(capacity: max(count, 1))
        guards.update(repeating: 0, count: max(count, 1))
        __sanitizer_cov_trace_pc_guard_init(guards, guards + count)
        return guards
    }

    /// Fires one guard exactly as an instrumented edge would.
    package static func fireGuardForTesting(_ guardPointer: UnsafeMutablePointer<UInt32>) {
        __sanitizer_cov_trace_pc_guard(guardPointer)
    }

    #if DEBUG
        /// Forgets every registered guard and unbinds the calling thread. Debug builds only; the C symbol does not exist in a release build, so the released binary cannot have its registry cleared.
        package static func resetRegistryForTesting() {
            exhaust_tpg_reset_registry_for_testing()
        }
    #endif
}
