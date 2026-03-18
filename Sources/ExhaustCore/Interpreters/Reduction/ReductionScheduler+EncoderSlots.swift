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

    // MARK: - Default cycle budget

    /// Default per-cycle materialization budget.
    ///
    /// Sized to allow thorough reduction for typical generators. The per-leg weights distribute this across the V-cycle legs.
    static let defaultCycleBudgetTotal = 3250

    /// Maximum per-cycle budget for the redistribution leg, separate from the main cycle budget.
    ///
    /// The actual budget is computed adaptively by ``ReductionState/adaptiveRedistributionBudget`` from the estimated costs of all redistribution encoders, capped at this value. For small generators with few values, the budget scales down to avoid wasting materializations; for large generators, this cap prevents runaway spending.
    static let defaultRedistributionBudget = 300

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
