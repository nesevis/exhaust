// The clustered fault inventory: reduction as a discrimination signal, not just a report.

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
/// Cluster identity is the reduced choice sequence — shortlex determinism makes it a strong equality. Signatures collect *within* a cluster: a second distinct signature on the same reduced form is the "likely same cluster" taxonomy tier (same surface bug, possibly different code paths reaching the fault), while a different reduced form is always a different cluster.
package struct FaultCluster: Sendable {
    /// Stable identifier in discovery order.
    package let id: Int

    /// The canonical (first-recorded) reduced choice sequence.
    package let reducedSequence: ChoiceSequence

    /// A rendered description of the reduced counterexample, for the report.
    package let reducedDescription: String

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

    /// The phase whose failure first created this cluster.
    package let discoveringPhase: SprawlPhase

    fileprivate init(
        id: Int,
        reducedSequence: ChoiceSequence,
        reducedDescription: String,
        signature: BitSet?,
        symptom: FailureSymptom,
        phase: SprawlPhase,
        timestampNanoseconds: UInt64
    ) {
        self.id = id
        self.reducedSequence = reducedSequence
        self.reducedDescription = reducedDescription
        signatures = signature.map { [$0] } ?? []
        symptoms = [symptom]
        instanceCount = 1
        reducedCount = 1
        firstSeenNanoseconds = timestampNanoseconds
        lastSeenNanoseconds = timestampNanoseconds
        discoveringPhase = phase
    }

    /// Reconstructs a cluster from a progress-log record at resume. Restored counts and timestamps carry over verbatim; the phase and identity are those of the original discovery.
    package init(
        restoredID: Int,
        reducedSequence: ChoiceSequence,
        reducedDescription: String,
        signatures: [BitSet],
        symptoms: Set<FailureSymptom>,
        instanceCount: Int,
        reducedCount: Int,
        firstSeenNanoseconds: UInt64,
        lastSeenNanoseconds: UInt64,
        discoveringPhase: SprawlPhase
    ) {
        id = restoredID
        self.reducedSequence = reducedSequence
        self.reducedDescription = reducedDescription
        self.signatures = signatures
        self.symptoms = symptoms
        self.instanceCount = instanceCount
        self.reducedCount = reducedCount
        self.firstSeenNanoseconds = firstSeenNanoseconds
        self.lastSeenNanoseconds = lastSeenNanoseconds
        self.discoveringPhase = discoveringPhase
    }

    fileprivate mutating func absorb(
        signature: BitSet?,
        symptom: FailureSymptom,
        timestampNanoseconds: UInt64
    ) {
        if let signature, signatures.contains(signature) == false {
            signatures.append(signature)
        }
        symptoms.insert(symptom)
        instanceCount += 1
        reducedCount += 1
        lastSeenNanoseconds = max(lastSeenNanoseconds, timestampNanoseconds)
    }

    fileprivate mutating func absorbUnreduced(symptom: FailureSymptom, timestampNanoseconds: UInt64) {
        symptoms.insert(symptom)
        instanceCount += 1
        lastSeenNanoseconds = max(lastSeenNanoseconds, timestampNanoseconds)
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

/// Accumulates fault clusters as dispatched reductions complete.
///
/// Actor-isolated because reduction Tasks write concurrently while the exploration loop reads for failure-weight upgrades. Writes are infrequent (failures are rare relative to attempts) and reads take the last completed state, so the eventual-consistency window is bounded by the slowest in-flight reduction.
package actor FaultInventory {
    package private(set) var clusters: [FaultCluster] = []

    /// Failures recorded unreduced whose symptom matched no cluster at record time; merged by symptom into the report.
    package private(set) var unmatchedUnreducedCounts: [FailureSymptom: Int] = [:]

    package init() {}

    /// Records a completed reduction, joining an existing cluster when the reduced form is already known and creating a new cluster otherwise.
    ///
    /// - Parameters:
    ///   - reducedSequence: The reduced counterexample's choice sequence — the cluster key.
    ///   - reducedDescription: A rendered description of the reduced value, kept from the first member.
    ///   - signature: The post-hoc coverage signature from the attributed re-run, or nil when attribution was unavailable.
    ///   - symptom: The failure's cheap symptom.
    ///   - phase: The phase that discovered the failing input.
    ///   - timestampNanoseconds: Monotonic time of the discovery, supplied by the caller so tests stay deterministic.
    package func recordReduced(
        reducedSequence: ChoiceSequence,
        reducedDescription: String,
        signature: BitSet?,
        symptom: FailureSymptom,
        phase: SprawlPhase,
        timestampNanoseconds: UInt64
    ) -> ClusterClassification {
        if let index = clusters.firstIndex(where: { $0.reducedSequence == reducedSequence }) {
            clusters[index].absorb(
                signature: signature,
                symptom: symptom,
                timestampNanoseconds: timestampNanoseconds
            )
            return ClusterClassification(
                clusterID: clusters[index].id,
                isNewCluster: false,
                instanceCount: clusters[index].instanceCount,
                capReached: clusters[index].reducedCount >= SprawlTunables.perClusterReductionCap
            )
        }
        let cluster = FaultCluster(
            id: clusters.count,
            reducedSequence: reducedSequence,
            reducedDescription: reducedDescription,
            signature: signature,
            symptom: symptom,
            phase: phase,
            timestampNanoseconds: timestampNanoseconds
        )
        clusters.append(cluster)
        return ClusterClassification(
            clusterID: cluster.id,
            isNewCluster: true,
            instanceCount: 1,
            capReached: false
        )
    }

    /// Records a failure the backpressure gate declined to reduce, attributing it by symptom to the most recently seen matching cluster, or holding it unmatched.
    package func recordUnreduced(symptom: FailureSymptom, timestampNanoseconds: UInt64) {
        let matching = clusters.indices
            .filter { clusters[$0].symptoms.contains(symptom) }
            .max { clusters[$0].lastSeenNanoseconds < clusters[$1].lastSeenNanoseconds }
        if let index = matching {
            clusters[index].absorbUnreduced(symptom: symptom, timestampNanoseconds: timestampNanoseconds)
        } else {
            unmatchedUnreducedCounts[symptom, default: 0] += 1
        }
    }

    /// A point-in-time copy for checkpointing and the final report.
    package func snapshot() -> [FaultCluster] {
        clusters
    }

    /// Restores the inventory from progress-log records at resume. Must run before any new recording so restored cluster identifiers keep their original, contiguous values — `recordReduced` allocates the next identifier from the cluster count.
    package func restore(clusters restored: [FaultCluster]) {
        guard clusters.isEmpty else {
            return
        }
        clusters = restored.sorted { $0.id < $1.id }
    }
}
