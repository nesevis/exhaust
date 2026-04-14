// MARK: - Reducer Configuration

package extension Interpreters {
    /// Controls the reducer's pass pipeline: stall budget, beam search tuning, and visualization.
    struct ReducerConfiguration: Sendable {
        /// Maximum number of outer cycles with no improvement before terminating.
        public var maxStalls: Int

        /// When `true`, prints the choice tree before and after reduction as a bottom-up Unicode visualization.
        public var visualize: Bool = false

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
