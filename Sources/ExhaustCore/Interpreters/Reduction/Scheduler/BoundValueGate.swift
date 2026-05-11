//
//  BoundValueGate.swift
//  Exhaust
//

// MARK: - Bound Value Gate

/// Controls dispatch of bound value composition encoders within the scheduler's cycle loop.
///
/// Keyed by ``BindMetadata/fingerprint`` (stable across graph rebuilds) so that fruitless verdicts and stall budgets survive structural rebuilds without re-probing bind sites that have already been determined unproductive.
///
/// Three skip rules:
///
/// 1. **Per-cycle dedup**: after the first dispatch for a given bind within a cycle, subsequent dispatches are skipped.
/// 2. **Acceptance deferral**: bound value dispatches are skipped when any encoder has already accepted a probe this cycle.
/// 3. **Fruitless tracking**: binds whose classification or last dispatch was unproductive are skipped. Persists across rebuilds because fingerprints are source-location-stable.
struct BoundValueGate {
    enum Decision {
        case dispatch
        case skip
        case classifyFirst
    }

    private var dispatchedThisCycle = Set<UInt64>()
    private var stallCount: [UInt64: Int] = [:]
    private var fruitless = Set<UInt64>()

    private static let baseBudget = 15

    mutating func resetForNewCycle() {
        dispatchedThisCycle.removeAll(keepingCapacity: true)
    }

    func shouldDispatch(
        fingerprint: UInt64,
        anyAcceptedThisCycle: Bool
    ) -> Decision {
        if dispatchedThisCycle.contains(fingerprint) {
            return .skip
        }
        if anyAcceptedThisCycle {
            return .skip
        }
        if fruitless.contains(fingerprint) {
            return .skip
        }
        return .classifyFirst
    }

    mutating func markDispatched(_ fingerprint: UInt64) {
        dispatchedThisCycle.insert(fingerprint)
    }

    mutating func markFruitless(_ fingerprint: UInt64) {
        fruitless.insert(fingerprint)
    }

    func decayedBudget(fingerprint: UInt64) -> Int {
        let stalls = stallCount[fingerprint, default: 0]
        return max(1, Self.baseBudget >> stalls)
    }

    mutating func recordOutcome(fingerprint: UInt64, accepted: Bool) {
        if accepted {
            stallCount[fingerprint] = 0
            fruitless.remove(fingerprint)
        } else {
            stallCount[fingerprint, default: 0] += 1
            fruitless.insert(fingerprint)
        }
    }
}
