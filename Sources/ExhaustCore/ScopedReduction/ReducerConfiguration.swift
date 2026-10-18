// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls scoped reduction budgets, encoder selection, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        package let maxStalls: Int

        /// Cooperative elapsed-time budget for reduction search, in nanoseconds. Checked between dispatch and probe steps, including post-cycle search passes. In-flight materializations and property invocations complete before search stops. The enabled final numeric reorder pass still runs to completion after expiry, so its materializations and property calls can exceed this budget. Zero means no limit.
        package var wallClockDeadlineNanoseconds: UInt64

        /// Restricts dispatch, post-cycle probes, and excursion exploitation to the named encoders. Nil enables all encoders; an empty set disables every probe. Branch pivots, including improving fills and excursion perturbations, use ``EncoderName/branchPivot``; subtree substitutions and descendant promotions use ``EncoderName/substitution``. Use this to stage reduction in multiple passes (for example, structural-only followed by value-only).
        package let enabledEncoders: Set<EncoderName>?

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        package var visualize: Bool = false

        /// Tuning constants for the scheduler's internal heuristics.
        package let tuning: ScopedReductionTuning

        /// Wraps every probe's property invocation, receiving the candidate sequence that probe is testing.
        ///
        /// Nil for a host that does not observe individual probes, which is the default. The one shipping client is the fuzz loop's crash breadcrumb, which marks the probe's own sequence as in flight so an abnormal termination names it rather than the last search candidate.
        package var probeWrapper: ProbeWrapper?

        /// Creates a configuration with the given stall budget and optional wall-clock deadline. Nil enables every encoder.
        package init(
            maxStalls: Int,
            wallClockDeadlineNanoseconds: UInt64 = 0,
            enabledEncoders: Set<EncoderName>? = nil,
            tuning: ScopedReductionTuning = .init(),
            probeWrapper: ProbeWrapper? = nil
        ) {
            self.maxStalls = maxStalls
            self.wallClockDeadlineNanoseconds = wallClockDeadlineNanoseconds
            self.enabledEncoders = enabledEncoders
            self.tuning = tuning
            self.probeWrapper = probeWrapper
        }
    }
}
