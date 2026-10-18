//
//  ScopedBatchedCrossSequenceRemovalSource.swift
//  Exhaust
//

// MARK: - Batched Cross-Sequence Removal Source

/// Attempts compatible sequences at their range minima first, then bisects the target list on rejection.
///
/// Tree traversal prefers outer sequences, prunes descendants inside deleted elements, and excludes targets invalidated by a changed bind inner. The initial all-sequence probe requires draining the selection cursor, but its compact plans share graph child storage and defer element-ID expansion until a scope is emitted.
///
/// A structural acceptance rebuilds the sources. Advancing this source therefore means the previous scope did not accept, so its range can be bisected without explicit feedback.
///
/// Prepared before the emptying family: a successful first probe can eliminate more structure in one materialization than emptying sequences individually.
final class ScopedBatchedCrossSequenceRemovalSource {
    private let plans: [TreeDeletionSelection.Plan]
    /// Stack of index ranges to try. Continuing after an unsuccessful scope appends its two halves.
    private var pendingRanges: [(start: Int, end: Int)]
    /// The last emitted range, bisected if this source is advanced again.
    private var lastEmittedRange: (start: Int, end: Int)?
    private var exhausted: Bool
    private var cachedPriority: DispatchPriority?
    /// True until the first scope is taken, so the all-sequence probe runs before ordinary priority ordering.
    private(set) var prefersInitialDispatch: Bool

    init(graph: ChoiceGraph) {
        plans = Self.treePlans(graph: graph)
        let count = plans.count
        // Only useful when there are at least two independent sequences to batch.
        if count >= 2 {
            pendingRanges = [(start: 0, end: count)]
            lastEmittedRange = nil
            exhausted = false
        } else {
            pendingRanges = []
            lastEmittedRange = nil
            exhausted = true
        }
        cachedPriority = nil
        prefersInitialDispatch = count >= 2
        recomputePriority()
    }

    var dispatchPriority: DispatchPriority? {
        cachedPriority
    }

    /// Continuing the same graph snapshot bisects the previous unsuccessful scope; accepted structural edits discard this source.
    func nextScope() -> PricedEncoderScope? {
        prefersInitialDispatch = false
        guard exhausted == false else {
            return nil
        }
        if let emitted = lastEmittedRange {
            lastEmittedRange = nil
            let count = emitted.end - emitted.start
            if count >= 2 {
                let midpoint = emitted.start + count / 2
                // The first half contains the highest-yield sequences and is popped first.
                pendingRanges.append((start: midpoint, end: emitted.end))
                pendingRanges.append((start: emitted.start, end: midpoint))
            }
        }

        guard let range = pendingRanges.popLast() else {
            exhausted = true
            cachedPriority = nil
            return nil
        }
        lastEmittedRange = range

        let indices = range.start ..< range.end
        let targets = plans[indices].map { $0.target }
        var totalYield = 0
        var maxElementYield = 0
        var maxBatch = 0
        for index in indices {
            let entryYield = plans[index].yield
            totalYield += entryYield
            if entryYield > maxElementYield {
                maxElementYield = entryYield
            }
            maxBatch += plans[index].deletableCount
        }

        let scope = ElementRemovalScope(
            targets: targets,
            maxBatch: maxBatch,
            maxElementYield: maxElementYield
        )

        recomputePriority()

        return PricedEncoderScope(
            encoderScope: .removal(.elements(scope)),
            priority: DispatchPriority(
                structuralBenefit: totalYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
        )
    }

    // MARK: - Helpers

    /// Drains lightweight plans for the initial all-sequence probe without expanding their element-ID arrays.
    private static func treePlans(graph: ChoiceGraph) -> [TreeDeletionSelection.Plan] {
        var cursor = TreeDeletionSelection.Cursor(graph: graph)
        var entries: [TreeDeletionSelection.Plan] = []
        while let plan = cursor.next() {
            entries.append(plan)
        }
        entries.sort { $0.yield > $1.yield }
        return entries
    }

    private func recomputePriority() {
        guard exhausted == false else {
            cachedPriority = nil
            return
        }
        if let range = pendingRanges.last {
            var totalYield = 0
            for index in range.start ..< range.end {
                totalYield += plans[index].yield
            }
            cachedPriority = DispatchPriority(
                structuralBenefit: totalYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            return
        }
        // Advertise the first half of the deferred bisection even when the stack is empty, so dispatch continues enumeration rather than dropping the source after its root scope.
        if let emitted = lastEmittedRange {
            let count = emitted.end - emitted.start
            guard count >= 2 else {
                cachedPriority = nil
                return
            }
            let midpoint = emitted.start + count / 2
            var firstHalfYield = 0
            for index in emitted.start ..< midpoint {
                firstHalfYield += plans[index].yield
            }
            cachedPriority = DispatchPriority(
                structuralBenefit: firstHalfYield,
                valueBenefit: 0,
                reductionMagnitude: 0,
                estimatedCost: 1
            )
            return
        }
        cachedPriority = nil
    }
}
