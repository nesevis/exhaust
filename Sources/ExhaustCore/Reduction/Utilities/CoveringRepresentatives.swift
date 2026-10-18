//
//  CoveringRepresentatives.swift
//  Exhaust
//

// MARK: - Covering Representatives

/// Chooses the values a budgeted pairwise covering search tries for each leaf.
///
/// A row covers at most one new combination per pair of leaves, so covering every combination of two leaves takes at least as many rows as the product of their domains. Giving each leaf ⌊√budget⌋ values lets the budget cover every combination of those values for a pair of leaves, instead of a sliver of the full pair space. The values are taken from both ends of the range, working inward: a range that a lift has just widened fails at its edges when it fails at all.
enum CoveringRepresentatives {
    /// Values per leaf whose pairwise combinations fit in `rowBudget` rows.
    static func perLeafCount(rowBudget: Int) -> Int {
        var count = 1
        while (count + 1) * (count + 1) <= rowBudget {
            count += 1
        }
        return count
    }

    /// Offsets from the domain's lower bound: every value when the domain holds at most `count`, otherwise the lowest, the highest, the second lowest, the second highest, and so on, `count` values in all.
    static func offsets(domainSize: UInt64, count: Int) -> [UInt64] {
        guard domainSize > UInt64(count) else {
            return Array(0 ..< domainSize)
        }
        var offsets: [UInt64] = []
        offsets.reserveCapacity(count)
        var step: UInt64 = 0
        while offsets.count < count {
            offsets.append(step)
            if offsets.count < count {
                offsets.append(domainSize &- 1 &- step)
            }
            step &+= 1
        }
        return offsets
    }
}
