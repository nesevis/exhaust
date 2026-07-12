// STADS completeness estimators for the fuzz report.
//
// Böhme, "STADS: Software Testing as Species Discovery" (ACM TOSEM 2018) transplants two
// ecological biostatistics estimators onto fuzzing campaigns: attempts are individuals, edges
// are species, and the only bookkeeping either estimator needs is how many edges were hit by
// exactly one attempt (singletons, f₁) and exactly two (doubletons, f₂). Both counts fall out
// of a per-edge incidence counter saturating at 3, maintained in the per-attempt snapshot walk
// the loop already performs.
//
// The estimates hold relative to the fuzzer's own search space — what this generator and this
// property can reach — never the module. That scoping is the point: it gives the report's
// coverage lines an honest denominator without any static reachability analysis.

/// Pure estimator arithmetic over singleton/doubleton edge counts. See the file header for provenance and scoping.
package enum CoverageEstimators {
    /// Good-Turing discovery probability `Û = f₁/n`: the estimated probability that the next attempt covers a new edge.
    ///
    /// Proven consistent as the sample grows, unlike the time-since-last-discovery signal it replaces, which swings four orders of magnitude minute to minute.
    package static func goodTuringNextDiscoveryProbability(singletons: Int, attempts: Int) -> Double {
        guard attempts > 0 else {
            return 0
        }
        return Double(singletons) / Double(attempts)
    }

    /// Chao1 species-richness estimate `Ŝ = S + ((n−1)/n) · f₁²/(2f₂)`: the asymptotic number of edges this search can reach.
    ///
    /// With no doubletons the ratio form is undefined; the standard bias-corrected variant `S + ((n−1)/n) · f₁(f₁−1)/2` substitutes. A run with no singletons estimates no undiscovered edges: `Ŝ = S`.
    package static func chao1ReachableEdges(covered: Int, singletons: Int, doubletons: Int, attempts: Int) -> Double {
        guard attempts > 1, singletons > 0 else {
            return Double(covered)
        }
        let sampleFactor = Double(attempts - 1) / Double(attempts)
        let undiscovered: Double = doubletons > 0
            ? Double(singletons) * Double(singletons) / (2 * Double(doubletons))
            : Double(singletons) * Double(singletons - 1) / 2
        return Double(covered) + sampleFactor * undiscovered
    }
}
