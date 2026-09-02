// Site-keyed dictionary of comparison operands harvested from the system under test.

/// Groups the operands the trace-cmp hooks harvest by comparison site, for the mutator to draw on during injection.
///
/// Keying by call site is what makes a cascade solvable. A shallow comparison fires on every attempt, so in a flat pool its constant floods every draw and the constants of deeper comparisons — which only fire once the earlier ones match — are never picked. With one small recency ring per site, each site's own recurring constant is a large share of that site's ring, and a draw that first picks a site uniformly gives every comparison, shallow or deep, an equal chance to contribute. Both operands of a comparison enter under its site key; which one is the wanted constant is not knowable, so the draw tries either.
///
/// The pool is written on every attempt, once per harvested operand, and read only when an injection arm draws. The layout serves the write: sites resolve through an open-addressing table with a Fibonacci hash of the call-site address rather than a `Dictionary` (which runs seeded SipHash per lookup), consecutive records from one site skip the lookup entirely, and every site's ring lives in one flat word array so an insert is two array stores with no nested-buffer uniqueness check. Site order is first-seen order, which is what `drawValue` indexes, so the layout leaves every draw unchanged.
package struct ComparisonPool: Sendable {
    /// Marks a free slot in `slotRings`.
    private static let emptySlot: Int32 = -1

    /// Open-addressing table: the site stored in each slot and the ring it maps to, or ``emptySlot``. Capacity is a power of two, kept at or below half full so linear probing stays short.
    private var slotSites: [UInt64]
    private var slotRings: [Int32]
    /// `log2` of the slot capacity, for the Fibonacci hash's shift.
    private var slotShift: Int

    /// Number of sites seen, which is also the number of rings.
    private var siteCount = 0

    /// Ring storage, `perSiteCapacity` words per site in first-seen site order.
    private var values: [UInt64] = []
    /// Live operands per ring, saturating at `perSiteCapacity`.
    private var counts: [Int32] = []
    /// Next overwrite position per full ring.
    private var cursors: [Int32] = []

    /// The site of the most recent insert and its ring, or a negative ring before the first insert. A comparison in a loop fires the same site many times in a row, so this skips the table for the common case.
    private var lastSite: UInt64 = 0
    private var lastRing = -1

    /// Recent operands retained per comparison site. Small, so a site's recurring constant dominates its own ring and stale operands age out quickly.
    private let perSiteCapacity: Int

    package init(perSiteCapacity: Int = 64) {
        self.perSiteCapacity = perSiteCapacity
        slotShift = 6
        slotSites = Array(repeating: 0, count: 1 << slotShift)
        slotRings = Array(repeating: Self.emptySlot, count: 1 << slotShift)
    }

    /// Records one harvested operand under its comparison site.
    package mutating func insert(site: UInt64, value: UInt64) {
        let ring = ringIndex(for: site)
        insert(value, intoRing: ring)
    }

    /// Records every operand of a contiguous record buffer: three words per record, the call-site address then both operands, the layout the coverage runtime's rings use. Equivalent to calling ``insert(site:value:)`` for each operand in buffer order, in one `mutating` call.
    package mutating func insert(records: UnsafeBufferPointer<UInt64>) {
        let recordCount = records.count / 3
        var index = 0
        while index < recordCount {
            let base = index * 3
            let ring = ringIndex(for: records[base])
            insert(records[base + 1], intoRing: ring)
            insert(records[base + 2], intoRing: ring)
            index += 1
        }
    }

    /// Whether the pool holds nothing to inject.
    package var isEmpty: Bool {
        siteCount == 0
    }

    /// Draws one operand: picks a comparison site uniformly, then a value from that site's ring.
    ///
    /// Uniform over sites rather than over all operands, so a site that fires rarely (a deep comparison reached only after earlier ones match) is drawn as often as one that fires constantly — the property that lets the frontier constant surface.
    ///
    /// - Parameters:
    ///   - sitePick: A uniform draw in [0, 1) selecting the site.
    ///   - valuePick: A uniform draw in [0, 1) selecting the value within the site.
    package func drawValue(sitePick: Double, valuePick: Double) -> UInt64? {
        guard siteCount > 0 else {
            return nil
        }
        let ring = Swift.min(Int(sitePick * Double(siteCount)), siteCount - 1)
        let count = Int(counts[ring])
        guard count > 0 else {
            return nil
        }
        return values[ring * perSiteCapacity + Swift.min(Int(valuePick * Double(count)), count - 1)]
    }

    // MARK: - Storage

    /// The ring for `site`, creating one on first sight.
    private mutating func ringIndex(for site: UInt64) -> Int {
        if lastRing >= 0, lastSite == site {
            return lastRing
        }
        let mask = slotSites.count - 1
        var slot = Self.slotIndex(for: site, shift: slotShift)
        while true {
            let ring = slotRings[slot]
            if ring == Self.emptySlot {
                break
            }
            if slotSites[slot] == site {
                lastSite = site
                lastRing = Int(ring)
                return Int(ring)
            }
            slot = (slot + 1) & mask
        }
        let ring = siteCount
        siteCount += 1
        slotSites[slot] = site
        slotRings[slot] = Int32(ring)
        values.append(contentsOf: repeatElement(0, count: perSiteCapacity))
        counts.append(0)
        cursors.append(0)
        if siteCount * 2 > slotSites.count {
            growSlots()
        }
        lastSite = site
        lastRing = ring
        return ring
    }

    /// Appends to a filling ring or overwrites oldest-first once it is full.
    private mutating func insert(_ value: UInt64, intoRing ring: Int) {
        let base = ring * perSiteCapacity
        let count = Int(counts[ring])
        if count < perSiteCapacity {
            values[base + count] = value
        } else {
            let cursor = Int(cursors[ring])
            values[base + cursor] = value
            let next = cursor + 1
            cursors[ring] = Int32(next == perSiteCapacity ? 0 : next)
            return
        }
        counts[ring] = Int32(count + 1)
    }

    /// Doubles the slot table and reinserts every site. Ring indices are untouched, so nothing that holds one goes stale.
    private mutating func growSlots() {
        let oldSites = slotSites
        let oldRings = slotRings
        slotShift += 1
        slotSites = Array(repeating: 0, count: 1 << slotShift)
        slotRings = Array(repeating: Self.emptySlot, count: 1 << slotShift)
        let mask = slotSites.count - 1
        for index in oldRings.indices where oldRings[index] != Self.emptySlot {
            var slot = Self.slotIndex(for: oldSites[index], shift: slotShift)
            while slotRings[slot] != Self.emptySlot {
                slot = (slot + 1) & mask
            }
            slotSites[slot] = oldSites[index]
            slotRings[slot] = oldRings[index]
        }
    }

    /// Fibonacci hashing: the top `shift` bits of the golden-ratio product. Call-site addresses share their low bits (instruction alignment) and their high bits (one image), and the multiply mixes both into the slot.
    @inline(__always)
    private static func slotIndex(for site: UInt64, shift: Int) -> Int {
        Int(truncatingIfNeeded: (site &* Xoshiro256.goldenRatioConstant) >> UInt64(64 - shift))
    }
}
