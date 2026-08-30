// Swift access to the SanitizerCoverage trace-cmp operand harvest defined in ExhaustCoverageRuntime.

// Internal so the C module stays out of ExhaustCore's emitted `.swiftinterface`. The hooks appear only in function bodies here, never in a `package` or `public` signature, so nothing needs the clang module to read the interface — which matters for the binary xcframework, whose consumers cannot resolve a source C target. A plain `import` would land in the textual interface and break its verification.
internal import ExhaustCoverageRuntime

/// Reads the comparison operands harvested by the trace-cmp hooks in ``ExhaustCoverageRuntime``.
///
/// The hooks record every instrumented comparison's operand pair into a ring buffer while harvesting is enabled. This type reads the process-global ring, which serves ``SancovCoverageSource``: the counter model has no per-run context, and the ring is shared the way its counter table is. ``TracePCGuardCoverageSource`` never reaches this ring; the hooks write to the ring inside the bound context instead, so guard runs harvest independently. ``reset()`` and ``setEnabled(_:)`` frame the property evaluation, and ``forEachRecord(_:)`` drains what fired.
package enum ComparisonRuntime {
    /// Turns operand recording on or off. Off between attempts, so only the property evaluation's comparisons are captured.
    package static func setEnabled(_ enabled: Bool) {
        exhaust_cmp_set_enabled(enabled ? 1 : 0)
    }

    /// Drops every operand recorded so far. Called at the start of an attempt bracket.
    package static func reset() {
        exhaust_cmp_reset()
    }

    /// Visits each `(site, arg1, arg2)` comparison record since the last ``reset()``.
    ///
    /// `site` is the comparison's call-site address, so operands from the same comparison group together. Which operand is the constant the comparison wanted and which is the value the attempt produced is not knowable here — both enter the pool under the same site key, and the mutator tries them, which is the spray-dictionary discipline: no attribution, cheap misses.
    package static func forEachRecord(_ body: (_ site: UInt64, _ arg1: UInt64, _ arg2: UInt64) -> Void) {
        let count = exhaust_cmp_record_count()
        guard count > 0, let base = exhaust_cmp_records() else {
            return
        }
        for index in 0 ..< count {
            body(base[index * 3], base[index * 3 + 1], base[index * 3 + 2])
        }
    }
}
