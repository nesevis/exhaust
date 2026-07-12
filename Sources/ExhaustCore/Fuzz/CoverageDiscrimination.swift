// Report-time statistics that turn per-invocation coverage signatures into fault-location suspects.

/// One edge's discrimination statistics for a fault cluster.
package struct EdgeDiscrimination: Sendable, Equatable {
    /// The global edge index.
    package let edge: Int

    /// The fraction of the cluster's reduced signatures that hit the edge — P(hit | fail) over the sharpest available failing sample.
    package let failureHitFraction: Double

    /// The fraction of passing corpus signatures that hit the edge — P(hit | pass).
    package let passingHitFraction: Double

    /// Discriminative power: `failureHitFraction / passingHitFraction`, with the denominator floored so edges no passing run hits rank highest instead of dividing by zero. An edge hit in every failure and every pass has power 1 and carries no information.
    package let power: Double
}

/// The report-time discrimination results for one fault cluster.
package struct ClusterDiscrimination: Sendable {
    /// The cluster these results belong to, by ``FaultCluster/id``.
    package let clusterID: Int

    /// Edges present in every reduced signature of the cluster — the path the SUT must traverse to reach this fault. Cheap (BitSet AND) and close to the minimal causal path because reduction has already stripped incidental coverage.
    package let necessaryEdges: BitSet

    /// The top discriminating edges, ranked by ``EdgeDiscrimination/power`` descending. Bounded by ``FuzzTunables/discriminatingEdgeLimit``.
    package let rankedEdges: [EdgeDiscrimination]

    /// Necessary edges absent from the passing signatures most similar to this cluster (highest Jaccard) — the branches that push the SUT from "almost fails" to "fails". Empty when the corpus has no passing entries to compare against.
    package let nearMissDistinguishingEdges: BitSet
}

/// Pure functions computing edge discrimination over accumulated signatures. Runs once at report time; the live loop only stores BitSets.
///
/// The failing sample is the cluster's post-reduction signatures rather than raw failing attempts: reduction strips incidental coverage (setup, logging, branches taken by coincidence), so the reduced signature has much higher signal density. The passing sample is the corpus's passing entries — a coverage-novelty-biased sample, which is fine for ranking: bias toward diverse passing paths widens the denominator's coverage rather than distorting which edges only failures hit.
package enum CoverageDiscrimination {
    /// Computes the discrimination results for one cluster against the passing corpus.
    ///
    /// - Parameters:
    ///   - clusterID: The cluster's stable identifier, carried through to the result.
    ///   - failingSignatures: The cluster's reduced signatures. Empty yields empty results.
    ///   - passingSignatures: Signatures of passing corpus entries.
    ///   - edgeCount: The signature capacity (instrumented edge count).
    /// - Returns: Necessary edges, ranked discriminating edges, and the near-miss differential.
    package static func discriminate(
        clusterID: Int,
        failingSignatures: [BitSet],
        passingSignatures: [BitSet],
        edgeCount: Int
    ) -> ClusterDiscrimination {
        let necessary = necessaryEdges(of: failingSignatures, edgeCount: edgeCount)
        let ranked = rankedEdges(
            failingSignatures: failingSignatures,
            passingSignatures: passingSignatures
        )
        let nearMiss = nearMissDifferential(
            necessaryEdges: necessary,
            passingSignatures: passingSignatures,
            edgeCount: edgeCount
        )
        return ClusterDiscrimination(
            clusterID: clusterID,
            necessaryEdges: necessary,
            rankedEdges: ranked,
            nearMissDistinguishingEdges: nearMiss
        )
    }

    /// Intersects the cluster's signatures: edges present in every failure are necessary conditions for the fault.
    package static func necessaryEdges(of signatures: [BitSet], edgeCount: Int) -> BitSet {
        guard var necessary = signatures.first else {
            return BitSet(capacity: edgeCount)
        }
        for signature in signatures.dropFirst() {
            necessary = necessary.intersection(signature)
        }
        return necessary
    }

    /// Ranks edges by discriminative power, keeping edges that discriminate at all (power above 1) up to the configured limit.
    ///
    /// Edges hit by every signature on both sides are common code (function entry, setup) and are excluded by the power cutoff, not by special-casing.
    package static func rankedEdges(
        failingSignatures: [BitSet],
        passingSignatures: [BitSet]
    ) -> [EdgeDiscrimination] {
        guard failingSignatures.isEmpty == false else {
            return []
        }
        var failCounts: [Int: Int] = [:]
        for signature in failingSignatures {
            signature.forEachIndex { edge in
                failCounts[edge, default: 0] += 1
            }
        }
        var passCounts: [Int: Int] = [:]
        for signature in passingSignatures {
            signature.forEachIndex { edge in
                passCounts[edge, default: 0] += 1
            }
        }

        let failTotal = Double(failingSignatures.count)
        let passTotal = Double(max(1, passingSignatures.count))
        // Floor the pass fraction at "less than one passing run" so never-passing edges rank highest with a finite power instead of dividing by zero.
        let passFloor = 1.0 / (passTotal + 1.0)

        var statistics: [EdgeDiscrimination] = []
        for (edge, failCount) in failCounts {
            let failFraction = Double(failCount) / failTotal
            let passFraction = Double(passCounts[edge] ?? 0) / passTotal
            let power = failFraction / max(passFraction, passFloor)
            guard power > 1.0 else {
                continue
            }
            statistics.append(EdgeDiscrimination(
                edge: edge,
                failureHitFraction: failFraction,
                passingHitFraction: passFraction,
                power: power
            ))
        }
        statistics.sort { lhs, rhs in
            if lhs.power != rhs.power {
                return lhs.power > rhs.power
            }
            return lhs.edge < rhs.edge
        }
        return Array(statistics.prefix(FuzzTunables.discriminatingEdgeLimit))
    }

    /// Finds the passing signatures most similar to the cluster's necessary-edge set and returns the necessary edges every one of them misses.
    ///
    /// This is Hypothesis's `explain` strategy adapted to the corpus: the near-misses walked almost the whole failing path, so what they lack is what distinguishes failing from almost-failing.
    package static func nearMissDifferential(
        necessaryEdges: BitSet,
        passingSignatures: [BitSet],
        edgeCount: Int
    ) -> BitSet {
        guard necessaryEdges.isEmpty == false, passingSignatures.isEmpty == false else {
            return BitSet(capacity: edgeCount)
        }
        let ranked = passingSignatures
            .map { signature in (signature: signature, similarity: necessaryEdges.jaccardSimilarity(to: signature)) }
            .sorted { $0.similarity > $1.similarity }
            .prefix(FuzzTunables.nearMissComparisonCount)

        // Edges present in the cluster but absent from every near-miss.
        var distinguishing = necessaryEdges
        for nearMiss in ranked {
            distinguishing = distinguishing.subtracting(nearMiss.signature)
        }
        return distinguishing
    }
}
