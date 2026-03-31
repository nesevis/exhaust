public extension Interpreters {
    /// Configuration presets for the reducer's test case reduction strategies.
    enum ReductionBudget: Sendable {
        /// Tuning parameters for the beam search used by aligned sibling deletion.
        struct AlignedDeletionBeamSearchTuning {
            let minBeamWidth: Int
            let beamWidthScale: Int
            let maxBeamWidth: Int
            let minEvaluationsPerLayer: Int
            let evaluationsPerLayerScale: Int

            static let fast = Self(
                minBeamWidth: 12,
                beamWidthScale: 2,
                maxBeamWidth: 48,
                minEvaluationsPerLayer: 6,
                evaluationsPerLayerScale: 1
            )

            static let slow = Self(
                minBeamWidth: 18,
                beamWidthScale: 3,
                maxBeamWidth: 96,
                minEvaluationsPerLayer: 10,
                evaluationsPerLayerScale: 2
            )

            func beamWidth(for slotCount: Int) -> Int {
                min(max(minBeamWidth, slotCount * beamWidthScale), maxBeamWidth)
            }

            func evaluationsPerLayer(for slotCount: Int, beamWidth: Int) -> Int {
                min(max(minEvaluationsPerLayer, slotCount * evaluationsPerLayerScale), beamWidth)
            }
        }

        case fast
        case slow
    }

    /// Backward-compatibility alias for ``ReductionBudget``.
    @available(*, deprecated, renamed: "ReductionBudget")
    typealias TCRConfiguration = ReductionBudget
}
