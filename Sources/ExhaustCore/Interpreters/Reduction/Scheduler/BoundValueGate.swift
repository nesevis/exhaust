//
//  BoundValueGate.swift
//  Exhaust
//

// MARK: - Bound Value Gate

/// Controls dispatch of bound value composition encoders within the scheduler's cycle loop.
///
/// Bound value compositions are expensive: each dispatch runs a generator lift per upstream probe and a fibre search per lift. The gate enforces three skip rules that prevent redundant or futile dispatches:
///
/// 1. **Per-cycle dedup**: after the first dispatch for a given bind node within a cycle, subsequent dispatches are skipped. The upstream encoder has already explored its full search space.
/// 2. **Acceptance deferral**: bound value dispatches are skipped when any encoder has already accepted a probe this cycle. Structural changes from the acceptance may invalidate the bound value search.
/// 3. **Fruitless tracking**: bind nodes whose last dispatch produced zero accepts are skipped until a structural rebuild clears the set.
///
/// The classification check (which may mutate the graph via ``ChoiceGraph/classifyBind``) is NOT handled by the gate. When `shouldDispatch` returns `.classifyFirst`, the caller performs classification and either proceeds or calls ``markFruitless(_:)``.
struct BoundValueGate {
    /// Result of the ``shouldDispatch(bindNodeID:anyAcceptedThisCycle:)`` check.
    enum Decision {
        /// The bind node passes all gate checks. The caller should proceed to classification (if not already cached) and then dispatch.
        case dispatch
        /// The bind node fails a gate check and should be skipped without further work.
        case skip
        /// The bind node passes the gate's own checks but has not been classified yet. The caller must run the classification check and either proceed to dispatch or call ``markFruitless(_:)``.
        case classifyFirst
    }

    private var dispatchedThisCycle = Set<Int>()
    private var stallCount: [Int: Int] = [:]
    private var fruitlessNodes = Set<Int>()

    /// Maximum upstream probes before any stall decay.
    private static let baseBudget = 15

    /// Clears per-cycle state at the start of each cycle.
    mutating func resetForNewCycle() {
        dispatchedThisCycle.removeAll(keepingCapacity: true)
    }

    /// Clears fruitless tracking after a structural graph rebuild.
    mutating func resetAfterRebuild() {
        fruitlessNodes.removeAll(keepingCapacity: true)
    }

    /// Checks whether a bound value composition should be dispatched for `bindNodeID`.
    ///
    /// - Parameters:
    ///   - bindNodeID: The bind node to consider dispatching.
    ///   - anyAcceptedThisCycle: Whether any encoder has accepted a probe in the current cycle.
    /// - Returns: `.dispatch` if the node passes all checks, `.skip` if it should be skipped, `.classifyFirst` if the caller must run classification before dispatching.
    func shouldDispatch(
        bindNodeID: Int,
        anyAcceptedThisCycle: Bool
    ) -> Decision {
        if dispatchedThisCycle.contains(bindNodeID) {
            return .skip
        }
        if anyAcceptedThisCycle {
            return .skip
        }
        if fruitlessNodes.contains(bindNodeID) {
            return .skip
        }
        return .classifyFirst
    }

    /// Records that a bound value composition has been dispatched for `bindNodeID` this cycle.
    mutating func markDispatched(_ bindNodeID: Int) {
        dispatchedThisCycle.insert(bindNodeID)
    }

    /// Records that a bind node's classification is incompatible with bound value search.
    mutating func markFruitless(_ bindNodeID: Int) {
        fruitlessNodes.insert(bindNodeID)
    }

    /// Returns the decay-adjusted upstream probe budget for a bind node.
    ///
    /// Decays exponentially with consecutive fruitless dispatches: 15, 7, 3, 1.
    func decayedBudget(bindNodeID: Int) -> Int {
        let stalls = stallCount[bindNodeID, default: 0]
        return max(1, Self.baseBudget >> stalls)
    }

    /// Records the outcome of a bound value dispatch.
    ///
    /// Accepted dispatches reset the stall counter and remove the node from the fruitless set. Rejected dispatches increment the stall counter and add the node to the fruitless set.
    mutating func recordOutcome(bindNodeID: Int, accepted: Bool) {
        if accepted {
            stallCount[bindNodeID] = 0
            fruitlessNodes.remove(bindNodeID)
        } else {
            stallCount[bindNodeID, default: 0] += 1
            fruitlessNodes.insert(bindNodeID)
        }
    }
}
