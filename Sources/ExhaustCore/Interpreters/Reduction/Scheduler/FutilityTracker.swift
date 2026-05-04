//
//  FutilityTracker.swift
//  Exhaust
//

// MARK: - Futility Tracker

/// Tracks cumulative per-encoder probe history and enforces per-cycle budgets for structurally futile encoders.
///
/// Some encoders are structurally futile on a given counterexample — they never find an accepted probe because the property's constraint structure makes the encoder's search space empty. After ``emitThreshold`` cumulative materializations with zero accepts, the encoder's per-cycle budget drops to ``budgetAfterCap``.
///
/// The budget acts as a heartbeat: enough probes per cycle to detect if the landscape changed (for example, a structural acceptance made the encoder viable), but not enough to waste significant materializations on a structurally hopeless search. If the encoder finds an accept, the cumulative accept count goes above zero and the cap lifts automatically.
///
/// Value search, float search, composed (bound value), and deletion are excluded because their acceptance pattern is dispatch-dependent or handled by other gating mechanisms.
struct FutilityTracker {
    private var emits: [EncoderName: Int] = [:]
    private var accepts: [EncoderName: Int] = [:]
    private var cycleBudgets: [EncoderName: Int] = [:]

    private static let emitThreshold = 10
    private static let budgetAfterCap = 2

    private static let excludedEncoders: Set<EncoderName> = [
        .valueSearch, .floatSearch, .composed, .deletion,
    ]

    /// Computes per-cycle budgets from cumulative history. Call at the start of each cycle.
    mutating func prepareForNewCycle() {
        cycleBudgets.removeAll(keepingCapacity: true)
        for (name, totalEmits) in emits {
            let totalAccepts = accepts[name, default: 0]
            guard totalAccepts == 0 else { continue }
            guard Self.excludedEncoders.contains(name) == false else { continue }
            if totalEmits >= Self.emitThreshold {
                cycleBudgets[name] = Self.budgetAfterCap
            }
        }
    }

    /// Whether the per-cycle budget for `encoder` has been exhausted.
    ///
    /// Returns false when there is no budget constraint (encoder has not hit the futility threshold or is excluded).
    func isBudgetExhausted(for encoder: EncoderName) -> Bool {
        guard let budget = cycleBudgets[encoder] else { return false }
        return budget <= 0
    }

    /// The remaining per-cycle materialization budget for `encoder`, or nil if unconstrained.
    ///
    /// Passed to ``ChoiceGraphScheduler/runProbeLoop`` as its `materializationBudget` parameter so the probe loop stops when the budget is spent.
    func remainingBudget(for encoder: EncoderName) -> Int? {
        cycleBudgets[encoder]
    }

    /// Records materializations and accepts from a completed probe loop dispatch.
    mutating func recordOutcome(encoder: EncoderName, materializations: Int, accepts: Int) {
        emits[encoder, default: 0] += materializations
        self.accepts[encoder, default: 0] += accepts
        if var budget = cycleBudgets[encoder] {
            budget -= materializations
            cycleBudgets[encoder] = budget
        }
    }

    /// Maps a ``GraphOperation`` to its ``EncoderName`` for tracking purposes.
    static func encoderName(for operation: GraphOperation) -> EncoderName {
        switch operation {
        case .remove: .deletion
        case .replace: .substitution
        case .minimize(.boundValue): .composed
        case .minimize(.valueLeaves): .valueSearch
        case .minimize(.floatLeaves): .floatSearch
        case .exchange(.redistribution): .redistribution
        case .exchange(.tandem): .lockstep
        case .permute: .siblingSwap
        case .migrate: .migration
        case .reorder: .numericReorder
        }
    }
}
