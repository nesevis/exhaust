// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls the reducer's pass pipeline: stall budget, beam search tuning, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public var maxStalls: Int

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

        /// When `true`, the scheduler appends one ``ProbeLogEntry`` per standard yield-merge dispatch to ``ReductionStats/probeLog``. Off by default because the log allocates per dispatch and is only useful for offline calibration analysis.
        public var collectProbeLog: Bool = false

        public init(
            maxStalls: Int
        ) {
            self.maxStalls = maxStalls
        }

        /// Preset for fast reduction with low stall tolerance.
        public static let fast = Self(maxStalls: 2)

        /// Preset for thorough reduction with higher stall tolerance.
        public static let slow = Self(maxStalls: 8)
    }
}
