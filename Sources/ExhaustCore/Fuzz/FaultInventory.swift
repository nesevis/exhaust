// The clustered fault inventory: reduction as a discrimination signal, not just a report.

import Foundation

/// The cheap synchronous identity of a failure, used for backpressure before reduction runs.
///
/// Symptom matching is deliberately the weak signal the inventory distrusts — two distinct bugs can share a symptom (slippage), which is why clustering keys on reduced forms instead. The symptom's only jobs are the per-cluster reduction cap and attributing unreduced failures to a plausible cluster.
package struct FailureSymptom: Hashable, Sendable {
    /// The thrown error's type name, or a fixed marker for properties that returned `false`.
    package let kind: String

    /// Creates a symptom from an error type name or marker.
    package init(kind: String) {
        self.kind = kind
    }

    /// The symptom of a property that returned `false` without throwing.
    package static let returnedFalse = FailureSymptom(kind: "returnedFalse")

    /// The symptom of a thrown error, keyed by its concrete type name.
    package static func thrown(_ error: any Error) -> FailureSymptom {
        FailureSymptom(kind: String(describing: type(of: error)))
    }
}

/// One fault class: a unique reduced form with its post-hoc coverage signatures and membership counts.
///
/// Cluster identity is the canonical structural key over the reduced sequence flattened with bind inners skipped (see ``Swift/Collection/clusterKey``). Raw sequence equality is not a reliable identity: two counterexamples that reduce to the same value through a bind or a length-coupled sequence carry different structural bookkeeping (`.sequence` valid ranges, `.branch` fingerprints, redundant bind-inner content) and would over-split into separate clusters; the key drops exactly that bookkeeping. Signatures collect *within* a cluster: a second distinct signature on the same reduced form is the "likely same cluster" taxonomy tier (same surface bug, possibly different code paths reaching the fault), while a different reduced form is always a different cluster.
package struct FaultCluster: Sendable {
    /// Stable identifier in discovery order. Settable within this file only, so ``FaultInventory/restore(clusters:)`` can renumber survivors contiguously after folding duplicates.
    package fileprivate(set) var id: Int

    /// The canonical (first-recorded) reduced choice sequence.
    package let reducedSequence: ChoiceSequence

    /// A rendered description of the reduced counterexample, for the report.
    package let reducedDescription: String

    /// The cluster's identity: the canonical structural key over the bind-inner-skipped flattening of the reduced sequence (see ``Swift/Collection/clusterKey``). Distinct from ``reducedDescription``, which is a depth-truncated rendering of the value for display.
    package let reducedKey: String

    /// The distinct post-hoc coverage signatures observed for this reduced form. More than one means "likely same cluster" members exist.
    package private(set) var signatures: [BitSet]

    /// The symptoms observed across this cluster's members.
    package private(set) var symptoms: Set<FailureSymptom>

    /// Total failures attributed to this cluster, reduced or not.
    package private(set) var instanceCount: Int

    /// Members that went through reduction (bounded by the per-cluster cap).
    package private(set) var reducedCount: Int

    /// Monotonic timestamps of the first and most recent attribution, for the report's late-discovery foregrounding.
    package private(set) var firstSeenNanoseconds: UInt64
    package private(set) var lastSeenNanoseconds: UInt64

    /// The 1-based attempt index of the earliest failure attributed to this cluster. Wall-clock timestamps move with machine load, so benchmarks compare this build-independent discovery metric instead; attribution takes the minimum rather than the first arrival so the metric never depends on recording order.
    package private(set) var firstSeenAttempt: Int

    /// Members whose own reduced form differed from this cluster's canonical form and joined only through normalization. A nonzero count means reduction stalled on some members (a masked flag bit, an unclamped byte) and the normalization pass re-drove them onto the canonical form instead of minting spurious clusters.
    package private(set) var unnormalizedMemberCount: Int

    /// The phase whose failure first created this cluster.
    package let discoveringPhase: FuzzPhase

    fileprivate init(
        id: Int,
        reducedSequence: ChoiceSequence,
        reducedDescription: String,
        reducedKey: String,
        signature: BitSet?,
        symptom: FailureSymptom,
        phase: FuzzPhase,
        timestampNanoseconds: UInt64,
        attemptIndex: Int,
        unnormalizedResidual: Bool
    ) {
        self.id = id
        self.reducedSequence = reducedSequence
        self.reducedDescription = reducedDescription
        self.reducedKey = reducedKey
        signatures = signature.map { [$0] } ?? []
        symptoms = [symptom]
        instanceCount = 1
        reducedCount = 1
        firstSeenNanoseconds = timestampNanoseconds
        lastSeenNanoseconds = timestampNanoseconds
        firstSeenAttempt = attemptIndex
        unnormalizedMemberCount = unnormalizedResidual ? 1 : 0
        discoveringPhase = phase
    }

    /// Reconstructs a cluster from a progress-log record at resume. Restored counts and timestamps carry over verbatim; the phase and identity are those of the original discovery.
    package init(
        restoredID: Int,
        reducedSequence: ChoiceSequence,
        reducedDescription: String,
        reducedKey: String,
        signatures: [BitSet],
        symptoms: Set<FailureSymptom>,
        instanceCount: Int,
        reducedCount: Int,
        firstSeenNanoseconds: UInt64,
        lastSeenNanoseconds: UInt64,
        firstSeenAttempt: Int,
        unnormalizedMemberCount: Int,
        discoveringPhase: FuzzPhase
    ) {
        id = restoredID
        self.reducedSequence = reducedSequence
        self.reducedDescription = reducedDescription
        self.reducedKey = reducedKey
        self.signatures = signatures
        self.symptoms = symptoms
        self.instanceCount = instanceCount
        self.reducedCount = reducedCount
        self.firstSeenNanoseconds = firstSeenNanoseconds
        self.lastSeenNanoseconds = lastSeenNanoseconds
        self.firstSeenAttempt = firstSeenAttempt
        self.unnormalizedMemberCount = unnormalizedMemberCount
        self.discoveringPhase = discoveringPhase
    }

    fileprivate mutating func absorb(
        signature: BitSet?,
        symptom: FailureSymptom,
        timestampNanoseconds: UInt64,
        attemptIndex: Int,
        unnormalizedResidual: Bool
    ) {
        if let signature, signatures.contains(signature) == false {
            signatures.append(signature)
        }
        symptoms.insert(symptom)
        instanceCount += 1
        reducedCount += 1
        lastSeenNanoseconds = max(lastSeenNanoseconds, timestampNanoseconds)
        firstSeenAttempt = min(firstSeenAttempt, attemptIndex)
        if unnormalizedResidual {
            unnormalizedMemberCount += 1
        }
    }

    /// Folds another record of the same fault into this one, the way ``absorb(signature:symptom:timestampNanoseconds:attemptIndex:unnormalizedResidual:)`` folds a live member: counts sum, sets union, first-seen takes the minimum and last-seen the maximum. The canonical form (sequence, description, key, discovering phase) stays this cluster's, which is the lower identifier's.
    fileprivate mutating func merge(_ other: FaultCluster) {
        id = Swift.min(id, other.id)
        signatures += other.signatures.filter { signatures.contains($0) == false }
        symptoms.formUnion(other.symptoms)
        instanceCount += other.instanceCount
        reducedCount += other.reducedCount
        firstSeenNanoseconds = Swift.min(firstSeenNanoseconds, other.firstSeenNanoseconds)
        lastSeenNanoseconds = Swift.max(lastSeenNanoseconds, other.lastSeenNanoseconds)
        firstSeenAttempt = Swift.min(firstSeenAttempt, other.firstSeenAttempt)
        unnormalizedMemberCount += other.unnormalizedMemberCount
    }

    fileprivate mutating func absorbUnreduced(
        symptom: FailureSymptom,
        timestampNanoseconds: UInt64,
        attemptIndex: Int
    ) {
        symptoms.insert(symptom)
        instanceCount += 1
        lastSeenNanoseconds = max(lastSeenNanoseconds, timestampNanoseconds)
        firstSeenAttempt = min(firstSeenAttempt, attemptIndex)
    }
}

/// The outcome of recording a completed reduction, fed back into parent-selection densification.
package struct ClusterClassification: Sendable {
    /// The cluster the reduction joined or created.
    package let clusterID: Int
    /// Whether the reduction created the cluster — new clusters densify aggressively.
    package let isNewCluster: Bool
    /// The cluster's instance count after this classification, which decays the existing-cluster boost.
    package let instanceCount: Int
    /// Whether the cluster's reduction cap is reached, ending its densification contribution.
    package let capReached: Bool
}

/// Accumulates fault clusters as reductions complete.
///
/// Lock-guarded rather than actor-isolated so the synchronous exploration loop can record, snapshot, and checkpoint without suspending or spawning Tasks whose completion nothing awaits. Production recording happens inline on the loop's lane; the lock is what keeps the `@unchecked Sendable` honest for any other context that inspects the inventory.
package final class FaultInventory: @unchecked Sendable {
    // @unchecked: all mutable state is guarded by `lock`, and no method suspends while holding it.
    private let lock = NSLock()
    private var clusters: [FaultCluster] = []

    /// How many distinct clusters have classified, without copying the snapshot.
    package var clusterCount: Int {
        lock.withLocking { clusters.count }
    }

    /// Cluster position by canonical reduced key, so classification stays O(1) as the inventory grows. `reducedKey` is immutable on a cluster, so entries never go stale; the index is rebuilt wholesale on ``restore(clusters:)``.
    private var clusterIndexByKey: [String: Int] = [:]

    /// The cluster ``recordUnreduced`` attributes each symptom to: the one carrying that symptom with the greatest `lastSeenNanoseconds`, ties broken by the lowest index. Scanning every cluster per call made the gate's highest-volume path linear in the inventory. A resumed run has clusters it never recorded, so ``restore(clusters:)`` rebuilds this too.
    private var attributionBySymptom: [FailureSymptom: Int] = [:]
    private var unmatchedBySymptom: [FailureSymptom: Int] = [:]

    package init() {}

    /// Failures recorded unreduced whose symptom matched no cluster at record time; merged by symptom into the report.
    package var unmatchedUnreducedCounts: [FailureSymptom: Int] {
        lock.withLocking { unmatchedBySymptom }
    }

    /// Records a completed reduction, joining an existing cluster when the reduced form is already known and creating a new cluster otherwise.
    ///
    /// - Parameters:
    ///   - reducedSequence: The reduced counterexample's choice sequence, kept from the first member.
    ///   - reducedKey: The canonical cluster identity — a metadata-stripped structural key over the reduced sequence (see ``Swift/Collection/clusterKey``).
    ///   - renderDescription: Produces the human-readable counterexample description, called only when a new cluster is created so its cost (reflection on the value) is paid once per fault, not once per reduction.
    ///   - signature: The post-hoc coverage signature from the attributed re-run, or nil when attribution was unavailable.
    ///   - symptom: The failure's cheap symptom.
    ///   - phase: The phase that discovered the failing input.
    ///   - timestampNanoseconds: Monotonic time of the discovery, supplied by the caller so tests stay deterministic.
    ///   - attemptIndex: The 1-based attempt index at which the failing input was observed — the discovery moment, not the classification moment, so out-of-order reduction completion cannot distort attempt-indexed metrics.
    ///   - unnormalizedResidual: Whether this member's own reduced form differed from `reducedKey` and joined only through the normalization pass.
    package func recordReduced(
        reducedSequence: ChoiceSequence,
        reducedKey: String,
        renderDescription: () -> String,
        signature: BitSet?,
        symptom: FailureSymptom,
        phase: FuzzPhase,
        timestampNanoseconds: UInt64,
        attemptIndex: Int,
        unnormalizedResidual: Bool = false
    ) -> ClusterClassification {
        lock.withLocking {
            if let index = clusterIndexByKey[reducedKey] {
                clusters[index].absorb(
                    signature: signature,
                    symptom: symptom,
                    timestampNanoseconds: timestampNanoseconds,
                    attemptIndex: attemptIndex,
                    unnormalizedResidual: unnormalizedResidual
                )
                refreshAttribution(forClusterAt: index)
                return ClusterClassification(
                    clusterID: clusters[index].id,
                    isNewCluster: false,
                    instanceCount: clusters[index].instanceCount,
                    capReached: clusters[index].reducedCount >= FuzzTunables.perClusterReductionCap
                )
            }
            let cluster = FaultCluster(
                id: clusters.count,
                reducedSequence: reducedSequence,
                reducedDescription: renderDescription(),
                reducedKey: reducedKey,
                signature: signature,
                symptom: symptom,
                phase: phase,
                timestampNanoseconds: timestampNanoseconds,
                attemptIndex: attemptIndex,
                unnormalizedResidual: unnormalizedResidual
            )
            clusterIndexByKey[reducedKey] = clusters.count
            clusters.append(cluster)
            refreshAttribution(forClusterAt: clusters.count - 1)
            return ClusterClassification(
                clusterID: cluster.id,
                isNewCluster: true,
                instanceCount: 1,
                capReached: false
            )
        }
    }

    /// Records a failure the backpressure gate declined to reduce, attributing it by symptom to the most recently seen matching cluster, or holding it unmatched.
    package func recordUnreduced(symptom: FailureSymptom, timestampNanoseconds: UInt64, attemptIndex: Int) {
        lock.withLocking {
            if let index = attributionBySymptom[symptom] {
                clusters[index].absorbUnreduced(
                    symptom: symptom,
                    timestampNanoseconds: timestampNanoseconds,
                    attemptIndex: attemptIndex
                )
                refreshAttribution(forClusterAt: index)
            } else {
                unmatchedBySymptom[symptom, default: 0] += 1
            }
        }
    }

    /// Re-points ``attributionBySymptom`` at the cluster whose timestamp just advanced. Only that cluster changed, so only it can have become the argmax; the tie-break reproduces the lowest-index rule the linear scan had.
    private func refreshAttribution(forClusterAt index: Int) {
        let cluster = clusters[index]
        for symptom in cluster.symptoms {
            guard let held = attributionBySymptom[symptom] else {
                attributionBySymptom[symptom] = index
                continue
            }
            let heldTimestamp = clusters[held].lastSeenNanoseconds
            if heldTimestamp < cluster.lastSeenNanoseconds
                || (heldTimestamp == cluster.lastSeenNanoseconds && index < held)
            {
                attributionBySymptom[symptom] = index
            }
        }
    }

    /// Whether a cluster with the given canonical key already exists — the normalization pass's pre-check, so the (comparatively expensive) probing runs only on the rare would-be-new-cluster event.
    ///
    /// `recordReduced` merges by key regardless of this pre-check's answer, so a stale read can only cost duplicated probing, never a duplicated cluster.
    package func containsKey(_ reducedKey: String) -> Bool {
        lock.withLocking { clusterIndexByKey[reducedKey] != nil }
    }

    /// A point-in-time copy for checkpointing and the final report.
    package func snapshot() -> [FaultCluster] {
        lock.withLocking { clusters }
    }

    /// Restores the inventory from progress-log records at resume. Must run before any new recording so restored cluster identifiers keep their original, contiguous values — `recordReduced` allocates the next identifier from the cluster count.
    ///
    /// Records sharing a `reducedKey` are folded into one cluster, and the survivors are renumbered contiguously so the identifier allocation stays a count. Duplicates are an ordinary occurrence rather than corruption: recovery re-derives the key from the materialized tree, and a derivation that over-split one fault legitimately brings two stored clusters onto one key. Indexing without folding would leave the array holding two clusters with one identity and only one of them reachable.
    ///
    /// - Returns: False when the inventory had already recorded, in which case nothing was restored.
    @discardableResult
    package func restore(clusters restored: [FaultCluster]) -> Bool {
        lock.withLocking {
            guard clusters.isEmpty else {
                return false
            }
            clusters = FaultInventory.fold(restored.sorted { $0.id < $1.id })
            clusterIndexByKey = Dictionary(uniqueKeysWithValues: clusters.enumerated().map { ($1.reducedKey, $0) })
            attributionBySymptom = [:]
            for index in clusters.indices {
                refreshAttribution(forClusterAt: index)
            }
            return true
        }
    }

    /// Merges same-key records the way the live path would have, keeping the lowest identifier's canonical form and renumbering the survivors contiguously.
    private static func fold(_ restored: [FaultCluster]) -> [FaultCluster] {
        var positionByKey: [String: Int] = [:]
        var merged: [FaultCluster] = []
        for cluster in restored {
            guard let position = positionByKey[cluster.reducedKey] else {
                positionByKey[cluster.reducedKey] = merged.count
                merged.append(cluster)
                continue
            }
            merged[position].merge(cluster)
        }
        // Contiguous again, because `recordReduced` allocates the next identifier from the cluster count.
        for position in merged.indices {
            merged[position].id = position
        }
        return merged
    }
}
