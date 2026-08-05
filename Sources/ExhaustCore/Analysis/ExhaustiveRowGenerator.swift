/// Enumerates every point in a parameter space, in odometer order.
///
/// A covering array stops once its t-tuples are covered, which for a small space is a fraction of the points and leaves the rest untested however much budget remains. Whether an untested point holds the failure then depends on which rows the array happened to pick, and under a per-run covering seed that varies between runs. Enumeration removes the question: every point is tested, in the same order, on every run.
///
/// Rows advance least-significant parameter first, so the all-minimum row comes out first and early rows differ from it in one position. Callers that want the smallest counterexample surfaced early get it without sorting.
package final class ExhaustiveRowGenerator {
    private let domainSizes: [UInt64]
    private var odometer: [UInt64]
    private var exhausted: Bool

    /// The number of points in the space, saturating at ``UInt64/max`` rather than overflowing.
    package static func totalSpace(of domainSizes: [UInt64]) -> UInt64 {
        var total: UInt64 = 1
        for size in domainSizes {
            let (product, overflow) = total.multipliedReportingOverflow(by: size)
            if overflow {
                return .max
            }
            total = product
        }
        return total
    }

    package init(domainSizes: [UInt64]) {
        self.domainSizes = domainSizes
        odometer = [UInt64](repeating: 0, count: domainSizes.count)
        exhausted = domainSizes.isEmpty || domainSizes.contains(0)
    }

    /// Returns the next point, or `nil` once every point has been returned.
    package func next() -> CoveringArrayRow? {
        guard exhausted == false else {
            return nil
        }
        let row = CoveringArrayRow(values: odometer)
        var position = odometer.count - 1
        while position >= 0 {
            odometer[position] &+= 1
            if odometer[position] < domainSizes[position] {
                return row
            }
            odometer[position] = 0
            position -= 1
        }
        exhausted = true
        return row
    }
}
