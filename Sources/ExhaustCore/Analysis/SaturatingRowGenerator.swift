/// Emits a covering array's rows, then every point of the space the array left out.
///
/// A covering array stops once its t-tuples are covered. For a small space that is a fraction of the points, so screening returns with budget unspent and whichever points went untested decided by the covering seed. Continuing into the remainder spends the rest of the budget on the rest of the space, and a run long enough to reach the end has tested every point whatever the seed was.
///
/// Order matters under truncation. The covering array comes first because its rows are spread across all factors by construction, so a budget that stops early still sees every pair. Plain enumeration cannot lead: odometer order varies the first factor slowest, and a truncated run would spend every row on that factor's first value.
///
/// Only worth constructing for a space small enough to track: the emitted set holds one entry per covering row.
package final class SaturatingRowGenerator {
    private let domainSizes: [UInt64]
    private let covering: BalancedCoveringArrayGenerator
    private var emitted: Set<UInt64> = []
    private var remainder: ExhaustiveRowGenerator?

    package init(domainSizes: [UInt64], seed: UInt64) {
        self.domainSizes = domainSizes
        // The spread path never reports exhaustion, so a spread-mode covering generator would hold ``next()`` in the covering phase forever and the remainder would never run. Forcing the greedy path makes termination structural, and the small-space gate callers apply keeps its pairwise tracking trivial.
        covering = BalancedCoveringArrayGenerator(
            domainSizes: domainSizes,
            seed: seed,
            greedyThreshold: domainSizes.max().map { Int(clamping: $0) }
        )
    }

    /// Returns the next row, or `nil` once the covering array and the remaining points are both spent.
    ///
    /// Every returned row is distinct: a covering row repeating an earlier one is skipped rather than spent, so no point costs the caller more than one property invocation.
    package func next() -> CoveringArrayRow? {
        if remainder == nil {
            while let row = covering.next() {
                if emitted.insert(Self.index(of: row.values, in: domainSizes)).inserted {
                    return row
                }
            }
            remainder = ExhaustiveRowGenerator(domainSizes: domainSizes)
        }
        while let row = remainder?.next() {
            if emitted.contains(Self.index(of: row.values, in: domainSizes)) == false {
                return row
            }
        }
        return nil
    }

    /// Mixed-radix index of a point, used as its identity in ``emitted``.
    private static func index(of values: [UInt64], in domainSizes: [UInt64]) -> UInt64 {
        var index: UInt64 = 0
        for (value, size) in zip(values, domainSizes) {
            index = index &* size &+ value
        }
        return index
    }
}
