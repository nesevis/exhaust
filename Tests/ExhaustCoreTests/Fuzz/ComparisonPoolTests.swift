//
//  ComparisonPoolTests.swift
//  ExhaustTests
//

import ExhaustCore
import Testing

@Suite("Comparison Pool")
struct ComparisonPoolTests {
    // MARK: - Emptiness

    @Test("An empty pool reports empty and draws nothing")
    func emptyPoolDrawsNothing() {
        let pool = ComparisonPool()
        #expect(pool.isEmpty)
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.0) == nil)
        #expect(pool.drawValue(sitePick: 0.999, valuePick: 0.999) == nil)
    }

    @Test("One insert makes the pool non-empty and every pick pair draws that value")
    func singleValueDrawsFromAnyPick() {
        var pool = ComparisonPool()
        pool.insert(site: 0xA, value: 42)
        #expect(pool.isEmpty == false)
        for pick in [0.0, 0.25, 0.5, 0.75, 0.999] {
            #expect(pool.drawValue(sitePick: pick, valuePick: pick) == 42)
        }
    }

    // MARK: - Site-Keyed Uniformity

    @Test("A site flooded with inserts is drawn no more often than a site holding one value")
    func siteDrawIsUniformOverSitesNotInsertions() {
        var pool = ComparisonPool()
        let hotSite: UInt64 = 0xCAFE
        let coldSite: UInt64 = 0xC01D
        for _ in 0 ..< 1000 {
            pool.insert(site: hotSite, value: 1)
        }
        pool.insert(site: coldSite, value: 2)

        // Two sites: the pick interval splits at 0.5 regardless of how many operands each site absorbed. This is the property that surfaces a rare deep comparison's constant against a shallow comparison that fires every attempt.
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.0) == 1)
        #expect(pool.drawValue(sitePick: 0.499, valuePick: 0.0) == 1)
        #expect(pool.drawValue(sitePick: 0.5, valuePick: 0.0) == 2)
        #expect(pool.drawValue(sitePick: 0.999, valuePick: 0.0) == 2)
    }

    @Test("Sites split the pick interval evenly in insertion order")
    func sitesSplitPickIntervalInInsertionOrder() {
        var pool = ComparisonPool()
        pool.insert(site: 0x1, value: 10)
        pool.insert(site: 0x2, value: 20)
        pool.insert(site: 0x3, value: 30)
        pool.insert(site: 0x4, value: 40)

        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.0) == 10)
        #expect(pool.drawValue(sitePick: 0.26, valuePick: 0.0) == 20)
        #expect(pool.drawValue(sitePick: 0.51, valuePick: 0.0) == 30)
        #expect(pool.drawValue(sitePick: 0.76, valuePick: 0.0) == 40)
    }

    @Test("Re-inserting into an existing site adds no site slot")
    func reinsertionDoesNotWidenTheSiteSplit() {
        var pool = ComparisonPool()
        pool.insert(site: 0x1, value: 10)
        pool.insert(site: 0x2, value: 20)
        pool.insert(site: 0x1, value: 11)

        // Still two sites: the boundary stays at 0.5 and site 0x1's second value is reachable through valuePick.
        #expect(pool.drawValue(sitePick: 0.49, valuePick: 0.99) == 11)
        #expect(pool.drawValue(sitePick: 0.5, valuePick: 0.0) == 20)
    }

    // MARK: - Value Draw Within a Site

    @Test("valuePick indexes a site's values by fraction, in insertion order")
    func valuePickIndexesByFraction() {
        var pool = ComparisonPool()
        for value in [10, 20, 30, 40] {
            pool.insert(site: 0x1, value: UInt64(value))
        }
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.0) == 10)
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.26) == 20)
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.51) == 30)
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.76) == 40)
    }

    @Test("Picks at the top of the unit interval clamp to the last site and value instead of trapping")
    func picksAtOneClampToLastIndex() {
        var pool = ComparisonPool()
        pool.insert(site: 0x1, value: 10)
        pool.insert(site: 0x2, value: 20)
        #expect(pool.drawValue(sitePick: 1.0, valuePick: 1.0) == 20)
    }

    // MARK: - Ring Eviction

    @Test("A full site ring overwrites oldest-first and evicted values become undrawable")
    func ringEvictsOldestFirst() {
        var pool = ComparisonPool(perSiteCapacity: 4)
        for value in [10, 20, 30, 40, 50, 60] {
            pool.insert(site: 0x1, value: UInt64(value))
        }
        // Positions after wrap: 50 and 60 overwrote 10 and 20; 30 and 40 survive in place.
        #expect(drawnValues(from: pool) == [50, 60, 30, 40])
    }

    @Test("A ring that wraps completely holds exactly the newest capacity-many values")
    func ringFullWrapHoldsNewestValues() {
        var pool = ComparisonPool(perSiteCapacity: 4)
        for value in 1 ... 10 {
            pool.insert(site: 0x1, value: UInt64(value))
        }
        // Ten inserts into capacity four: 9 and 10 landed after the second wrap, on top of 5 and 6.
        #expect(Set(drawnValues(from: pool)) == [7, 8, 9, 10])
    }

    @Test("Eviction in one site leaves another site's values untouched")
    func evictionIsPerSite() {
        var pool = ComparisonPool(perSiteCapacity: 2)
        pool.insert(site: 0x2, value: 99)
        for value in [10, 20, 30] {
            pool.insert(site: 0x1, value: UInt64(value))
        }
        #expect(pool.drawValue(sitePick: 0.0, valuePick: 0.0) == 99)
        #expect(pool.drawValue(sitePick: 0.99, valuePick: 0.0) == 30)
        #expect(pool.drawValue(sitePick: 0.99, valuePick: 0.99) == 20)
    }

    // MARK: - Helpers

    /// Reads a single-site pool's ring positionally, by sweeping `valuePick` across the slot midpoints.
    private func drawnValues(from pool: ComparisonPool, slots: Int = 4) -> [UInt64] {
        (0 ..< slots).compactMap { index in
            pool.drawValue(sitePick: 0.0, valuePick: (Double(index) + 0.5) / Double(slots))
        }
    }
}
