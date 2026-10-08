// STADS completeness estimators for the fuzz report.
//
// Böhme, "STADS: Software Testing as Species Discovery" (ACM TOSEM 2018) transplants ecological biostatistics onto fuzzing campaigns: test inputs are sampling units, edges are species.
//
// The paper separates two models, and edge coverage is the second one. In the multinomial model (§3.5) one input belongs to exactly one species, which is abundance data. In the Bernoulli product model (§7) one input belongs to one or more species, which is incidence data.
//
// A single attempt covers thousands of edges at once, so an attempt is a sampling unit containing many species. That choice changes the estimators: richness comes from Chao2 and iChao2 rather than Chao1, and the discovery probability is denominated in total incidences V rather than in the number of attempts.
//
// The bookkeeping is the incidence frequency counts Qₖ (edges hit by exactly k attempts) and V, all maintained by the per-attempt offer walk the loop already performs.
//
// The estimates hold relative to the fuzzer's own search space — what this generator and this property can reach — never the module. That scoping is the point: it gives the report's coverage lines an honest denominator without any static reachability analysis.

/// Computes STADS completeness estimates from incidence frequency counts. See the file header for provenance, model choice, and scoping.
package enum CoverageEstimators {
    /// Discovery probability `Û = (Q₁/V) · [nQ̂₀ / (nQ̂₀ + Q₁)]`: the estimated probability that the next incidence is a species not yet seen.
    ///
    /// The Bernoulli-product form (Böhme Eq 28). Dividing by the attempt count instead — the multinomial Good-Turing form `Q₁/n` — overstates the probability by the mean number of edges an attempt covers, which for edge coverage is in the thousands.
    ///
    /// - Parameters:
    ///   - singletons: `Q₁`, edges hit by exactly one attempt.
    ///   - incidenceTotal: `V`, the sum of all entries in the incidence matrix.
    ///   - undiscovered: `Q̂₀`, estimated undiscovered edges — the Chao2 estimate minus what is covered.
    ///   - attempts: `n`, test inputs generated.
    package static func nextDiscoveryProbability(
        singletons: Int,
        incidenceTotal: Int,
        undiscovered: Double,
        attempts: Int
    ) -> Double {
        guard incidenceTotal > 0, singletons > 0 else {
            return 0
        }
        let base = Double(singletons) / Double(incidenceTotal)
        let scaled = Double(attempts) * undiscovered
        guard scaled > 0 else {
            return base
        }
        return base * (scaled / (scaled + Double(singletons)))
    }

    /// Chao2 richness estimate `Ŝ = S + ((n−1)/n) · Q₁²/(2Q₂)`: a lower bound on the edges this search can reach.
    ///
    /// A **lower bound**, not a point estimate (Böhme §4.2, Chao 1987). It is unbiased only while undetected and singleton species have approximately equal detection probability; when rare species are unevenly distributed it under-estimates, so treat `covered / reachable` as an upper bound on completeness.
    ///
    /// With no doubletons the ratio form is undefined and `S + ((n−1)/n) · Q₁(Q₁−1)/2` substitutes. A run with no singletons estimates no undiscovered edges: `Ŝ = S`.
    package static func chao2ReachableEdges(covered: Int, singletons: Int, doubletons: Int, attempts: Int) -> Double {
        guard attempts > 1, singletons > 0 else {
            return Double(covered)
        }
        let sampleFactor = Double(attempts - 1) / Double(attempts)
        let undiscovered: Double = doubletons > 0
            ? Double(singletons) * Double(singletons) / (2 * Double(doubletons))
            : Double(singletons) * Double(singletons - 1) / 2
        return Double(covered) + sampleFactor * undiscovered
    }

    /// iChao2 improved lower bound: Chao2 plus a tripleton/quadrupleton correction (Böhme Eq 27, Chui et al.).
    ///
    /// Sharper than Chao2 whenever quadrupletons exist, and most useful exactly where Chao2 is weakest — a small doubleton count makes `Q₁²/(2Q₂)` swing hard on one edge, and the correction term does not share that denominator. Falls back to Chao2 when `Q₄` is zero.
    package static func iChao2ReachableEdges(
        covered: Int,
        singletons: Int,
        doubletons: Int,
        tripletons: Int,
        quadrupletons: Int,
        attempts: Int
    ) -> Double {
        let chao2 = chao2ReachableEdges(
            covered: covered,
            singletons: singletons,
            doubletons: doubletons,
            attempts: attempts
        )
        guard quadrupletons > 0, tripletons > 0, attempts > 3 else {
            return chao2
        }
        let sampleFactor = Double(attempts - 3) / Double(attempts)
        let ratio = Double(tripletons) / (4 * Double(quadrupletons))
        let inner = Double(singletons)
            - Double(attempts - 3) / Double(attempts - 1)
            * Double(doubletons) * Double(tripletons) / (2 * Double(quadrupletons))
        return chao2 + sampleFactor * ratio * max(inner, 0)
    }
}
