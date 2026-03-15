extension ReductionScheduler {
    // MARK: - Leg Budget Tracker

    /// Tracks materialization budget within a single V-cycle leg.
    ///
    /// Two counters: `used` (total materializations, capped by `hardCap`) and `consecutiveFruitless` (consecutive failures, capped by `stallPatience`). A success resets the fruitless counter.
    struct LegBudget {
        /// Maximum total materializations this leg may consume.
        let hardCap: Int
        /// Maximum consecutive fruitless materializations before the leg gives up.
        let stallPatience: Int

        /// Total materializations consumed so far.
        private(set) var used = 0
        /// Consecutive materializations without an accepted candidate.
        private(set) var consecutiveFruitless = 0

        /// Returns `true` when either the hard cap or the stall patience has been reached.
        var isExhausted: Bool {
            used >= hardCap || consecutiveFruitless >= stallPatience
        }

        /// Records a materialization attempt, resetting the fruitless counter on acceptance.
        mutating func recordMaterialization(accepted: Bool) {
            used += 1
            if accepted {
                consecutiveFruitless = 0
            } else {
                consecutiveFruitless += 1
            }
        }
    }

    // MARK: - Default cycle budget

    /// Default per-cycle materialization budget.
    ///
    /// Sized to allow thorough reduction for typical generators. The per-leg weights distribute this across the V-cycle legs.
    static let defaultCycleBudgetTotal = 300

    // MARK: - Encoder Ordering

    /// Value minimization and reordering encoder slots, used by the snip and train legs.
    enum ValueEncoderSlot: CaseIterable {
        case zeroValue
        case binarySearchToZero
        case binarySearchToTarget
        case reduceFloat
        case reorderSiblings
    }

    /// Deletion encoder slots, used by the prune leg.
    enum DeletionEncoderSlot: CaseIterable {
        case containerSpans
        case sequenceElements
        case sequenceBoundaries
        case freeStandingValues
        case alignedWindows
        case speculativeDelete

        var spanCategory: DeletionSpanCategory {
            switch self {
            case .containerSpans: .containerSpans
            case .sequenceElements: .sequenceElements
            case .sequenceBoundaries: .sequenceBoundaries
            case .freeStandingValues: .freeStandingValues
            case .alignedWindows: .containerSpans
            case .speculativeDelete: .mixed
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
