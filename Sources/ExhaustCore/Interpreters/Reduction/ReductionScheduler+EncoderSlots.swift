/// Utility namespace for encoder slots, leg budget tracking, and move-to-front ordering.
///
/// Contains shared infrastructure used by ``BonsaiScheduler`` across all reduction phases: per-leg budget tracking (``LegBudget``), encoder slot enumerations (``ValueEncoderSlot``, ``DeletionEncoderSlot``), and the ``moveToFront(_:in:)`` helper for adaptive ordering.
enum ReductionScheduler {}

extension ReductionScheduler {
    // MARK: - Leg Budget Tracker

    /// Tracks materialization budget within a single V-cycle leg.
    ///
    /// Each encoder naturally exhausts its probe space (returns `nil` from `nextProbe`),
    /// so only the shared hard cap is needed to prevent any single encoder from monopolizing
    /// the leg's budget.
    struct LegBudget {
        /// Maximum total materializations this leg may consume.
        let hardCap: Int

        /// Total materializations consumed so far.
        private(set) var used = 0

        /// Returns `true` when the hard cap has been reached.
        var isExhausted: Bool {
            used >= hardCap
        }

        /// Records a materialization attempt.
        mutating func recordMaterialization() {
            used += 1
        }
    }

    // MARK: - Encoder Ordering

    /// Value minimization and reordering encoder slots, used by the snip and train legs.
    enum ValueEncoderSlot: CaseIterable {
        case zeroValue
        case binarySearchToZero
        case binarySearchToTarget
        case reduceFloat
    }

    /// Deletion encoder slots, used by the prune leg.
    enum DeletionEncoderSlot: CaseIterable {
        case containerSpans
        case sequenceElements
        case sequenceBoundaries
        case freeStandingValues
        case alignedWindows
        case randomRepairDelete

        var spanCategory: DeletionSpanCategory {
            switch self {
            case .containerSpans: .containerSpans
            case .sequenceElements: .sequenceElements
            case .sequenceBoundaries: .sequenceBoundaries
            case .freeStandingValues: .freeStandingValues
            case .alignedWindows: .containerSpans
            case .randomRepairDelete: .mixed
            }
        }
    }

    /// Promotes `slot` to the front of `order`. No-op if already at front.
    static func moveToFront<Slot: Equatable>(_ slot: Slot, in order: inout [Slot]) {
        guard let index = order.firstIndex(of: slot), index > 0 else { return }
        order.remove(at: index)
        order.insert(slot, at: 0)
    }
}
