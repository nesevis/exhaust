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

    /// Candidate discriminating edges, ranked by ``EdgeDiscrimination/power`` descending. Bounded by ``FuzzTunables/discriminatingEdgeCandidateLimit``; the report symbolizes them, folds edges that resolve to one source location, and keeps ``FuzzTunables/discriminatingEdgeLimit``.
    package let rankedEdges: [EdgeDiscrimination]
}

/// The corpus's passing entries as per-edge hit counts: the P(hit | pass) denominator, counted once for every cluster.
///
/// Counts rather than signatures: ranking needs only how many passing entries hit each edge, and holding the count array beside its sample size keeps a caller from pairing counts with a denominator they do not describe. Building per-entry bitmaps here was the last report-time `BitSet` construction after entries stopped storing signatures.
package struct PassingSample: Sendable {
    /// How many signatures hit each edge, indexed by edge. Edges at or beyond `edgeCount` are not represented.
    private let counts: [Int]

    /// The number of passing entries counted, the ranking's denominator.
    package let sampleSize: Int

    /// Counts one passing sample over an edge domain of `edgeCount` from each passing entry's hit edges.
    package init(passingHits: some Sequence<[(edge: Int, hitCount: UInt8)]>, edgeCount: Int) {
        var counts = [Int](repeating: 0, count: max(0, edgeCount))
        var sampleSize = 0
        for hits in passingHits {
            sampleSize += 1
            for (edge, _) in hits where edge >= 0 && edge < counts.count {
                counts[edge] += 1
            }
        }
        self.counts = counts
        self.sampleSize = sampleSize
    }

    /// Passing entries hitting `edge`, or zero for an edge outside the counted domain.
    package subscript(edge: Int) -> Int {
        counts.indices.contains(edge) ? counts[edge] : 0
    }
}

/// Pure functions computing edge discrimination over accumulated signatures. Runs once at report time; the live loop only stores per-cluster signatures.
///
/// The failing sample is the cluster's post-reduction signatures rather than raw failing attempts: reduction strips incidental coverage (setup, logging, branches taken by coincidence), so the reduced signature has much higher signal density. The passing sample is the corpus's passing entries, a coverage-novelty-biased sample, which is fine for ranking: bias toward diverse passing paths widens the denominator's coverage rather than distorting which edges only failures hit.
///
/// Ranking is the one analysis. A necessary-edge intersection and a near-miss differential (the necessary edges the closest passing signatures lack) were measured on 2026-09-06 and named nothing a reader acts on: on IFC the near-miss set pointed at the validity checks that rejected almost-failing runs, never at the mutated rule the ranking already found.
package enum CoverageDiscrimination {
    /// Computes the discrimination results for one cluster against the passing corpus.
    ///
    /// - Parameters:
    ///   - clusterID: The cluster's stable identifier, carried through to the result.
    ///   - failingSignatures: The cluster's reduced signatures. Empty yields empty results.
    ///   - passing: The passing corpus entries. Build it once and pass the same value to every cluster.
    package static func discriminate(
        clusterID: Int,
        failingSignatures: [BitSet],
        passing: PassingSample
    ) -> ClusterDiscrimination {
        ClusterDiscrimination(
            clusterID: clusterID,
            rankedEdges: rankedEdges(failingSignatures: failingSignatures, passing: passing)
        )
    }

    /// Ranks edges by discriminative power, keeping edges that discriminate at all (power above 1) up to `limit`.
    ///
    /// Edges hit by every signature on both sides are common code (function entry, setup) and are excluded by the power cutoff, not by special-casing. The default limit is the candidate pool the report folds by source location; several edges of one function usually rank together, and folding after symbolization is what keeps the printed list from spending its slots on one function's offsets.
    package static func rankedEdges(
        failingSignatures: [BitSet],
        passing: PassingSample,
        limit: Int = FuzzTunables.discriminatingEdgeCandidateLimit
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

        let failTotal = Double(failingSignatures.count)
        let passTotal = Double(max(1, passing.sampleSize))
        // Floor the pass fraction at "less than one passing run" so never-passing edges rank highest with a finite power instead of dividing by zero.
        let passFloor = 1.0 / (passTotal + 1.0)

        var statistics: [EdgeDiscrimination] = []
        for (edge, failCount) in failCounts {
            let failFraction = Double(failCount) / failTotal
            let passFraction = Double(passing[edge]) / passTotal
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
        return Array(statistics.prefix(limit))
    }
}
