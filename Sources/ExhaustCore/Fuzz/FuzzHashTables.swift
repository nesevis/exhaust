// Fixed-size hash tables the fuzz loop consults on every attempt: recently seen candidates, and per-source energy for comparand substitution.

// MARK: - Operand Energy Table

/// Remaining energy per key, for producers that should keep drawing a source while it yields and stop when it stops.
///
/// A fixed budget per source is a guess: too small on a workload where the source is productive, wasteful where it is not. Energy replaces the guess with the run's own evidence — a yield restores the budget, a barren draw spends one, so a source that keeps finding things is never retired and one that stops is retired quickly.
///
/// Open-addressed with a bounded linear probe: a key whose whole window is occupied by other keys evicts the first of them, which restores that source's budget. Losing the state costs re-exploration, never correctness.
///
/// The allowance resets in full on a yield rather than decaying with total draws, unlike ``FuzzCorpus/powerScheduleChildren(forParentAt:base:)``. That schedule damps a parent by children spawned because fuzzing a parent exhausts its neighbourhood; an operand's usefulness does not decay that way, because every parent it meets is a fresh context, so a heavily drawn operand is not a spent one.
package struct OperandEnergyTable {
    // MARK: - Live Sources

    //
    // Open-addressed with a bounded linear probe. Replacement on first collision was measured at 48% of seatings on the Etna IFC type-based workload, and every one of those restored the evicted source's allowance — retirement undone by collision rather than by yielding. A perfect hash does not fix that: 12,738 keys in 65,536 slots put ~9.7% of keys on an occupied slot by the birthday bound alone, so the structure was wrong, not the mixing. Probing seats elsewhere instead, and only a window full of other keys evicts.

    private var keys: [UInt64]
    private var sinceYield: [UInt8]
    private let mask: Int

    // MARK: - Retired Sources

    //
    // Retirement is monotonic: a source out of energy is never drawn again, so it can never yield, so it never needs un-retiring. A set with no deletions is a Bloom filter's shape, and it is the half that grows without bound — over a long campaign the retired set is operands times parents times tags, which an exact map cannot hold in fixed space. Retiring frees the source's slot, so the probe table's load stays low however long the run goes.
    //
    // The error direction is the one to watch. A probe-window eviction resurrects a source, which wastes at most one allowance and corrects itself. A filter false positive retires a live source permanently, with no recovery path and no signal. That is the worse failure, so the filter is sized to make it the rarer one: at the measured key count the false-positive rate is around 2e-8, well below the eviction rate the probe window leaves.

    private var retired: [UInt64]
    /// One below the filter's bit count, which is a power of two, so folding is a mask rather than a modulus.
    private let retiredBitMask: UInt64

    /// Probe length before a seat evicts. At the measured load a full window of foreign keys has probability ~2e-6.
    private static let probeWindow = 8

    /// Hashes per filter insertion.
    private static let filterHashes = 7

    /// Keys seated over another key because the whole probe window was occupied.
    package private(set) var evictions = 0

    /// Keys seated into a slot, whether it was empty or held another key.
    package private(set) var seatings = 0

    /// Sources moved into the retired filter.
    package private(set) var retirements = 0

    package init(capacityExponent: Int, filterBitExponent: Int = 20) {
        keys = Array(repeating: 0, count: 1 << capacityExponent)
        sinceYield = Array(repeating: 0, count: 1 << capacityExponent)
        mask = keys.count - 1
        let bitCount = 1 << filterBitExponent
        retiredBitMask = UInt64(bitCount - 1)
        retired = Array(repeating: 0, count: bitCount / 64)
    }

    /// Whether `key` may be drawn: not retired, and holding an allowance of `initial` barren draws that every yield restores in full.
    package mutating func hasEnergy(_ key: UInt64, initial: UInt8) -> Bool {
        guard filterContains(key) == false else {
            return false
        }
        return sinceYield[slot(key)] < initial
    }

    /// Records one draw's outcome against `key`, retiring it into the filter when its allowance runs out.
    package mutating func note(_ key: UInt64, yielded: Bool, initial: UInt8) {
        let index = slot(key)
        if yielded {
            sinceYield[index] = 0
            return
        }
        sinceYield[index] += 1
        if sinceYield[index] >= initial {
            filterInsert(key)
            keys[index] = 0
            sinceYield[index] = 0
            retirements += 1
        }
    }

    /// The slot holding `key`, seating it on the first free slot in its probe window. A window entirely occupied by other keys evicts the first of them.
    ///
    /// The whole window is scanned for the key before an empty slot is taken: retirement frees slots, and a key seated past a freed slot would otherwise be re-seated fresh there with its allowance restored.
    private mutating func slot(_ key: UInt64) -> Int {
        let home = Int(truncatingIfNeeded: key >> 24) & mask
        var firstEmpty: Int?
        for step in 0 ..< Self.probeWindow {
            let index = (home + step) & mask
            if keys[index] == key {
                return index
            }
            if keys[index] == 0, firstEmpty == nil {
                firstEmpty = index
            }
        }
        if firstEmpty == nil {
            evictions += 1
        }
        let index = firstEmpty ?? home
        keys[index] = key
        sinceYield[index] = 0
        seatings += 1
        return index
    }

    /// Double hashing: `h1 + i · h2`, computed unsigned and folded by a power-of-two mask. Signed arithmetic here wraps negative and indexes out of bounds.
    ///
    /// The filter runs at about 1% occupancy, so a live source finds a clear bit on its first probe and returns. The walk that visits every hash is the retired-source path alone.
    private func filterPositions(_ key: UInt64) -> (first: UInt64, step: UInt64) {
        var mixed = key &* 0xFF51_AFD7_ED55_8CCD
        mixed ^= mixed >> 33
        return (mixed, (mixed &* 0xC4CE_B9FE_1A85_EC53) | 1)
    }

    private func filterBit(_ first: UInt64, _ step: UInt64, _ hash: Int) -> Int {
        Int(truncatingIfNeeded: (first &+ UInt64(hash) &* step) & retiredBitMask)
    }

    private func filterContains(_ key: UInt64) -> Bool {
        let (first, step) = filterPositions(key)
        for hash in 0 ..< Self.filterHashes {
            let bit = filterBit(first, step, hash)
            if retired[bit >> 6] & (1 << UInt64(bit & 63)) == 0 {
                return false
            }
        }
        return true
    }

    private mutating func filterInsert(_ key: UInt64) {
        let (first, step) = filterPositions(key)
        for hash in 0 ..< Self.filterHashes {
            let bit = filterBit(first, step, hash)
            retired[bit >> 6] |= (1 << UInt64(bit & 63))
        }
    }
}

// MARK: - Recent Hash Table

/// A direct-mapped table of recently seen hashes.
///
/// Fixed size, because a `Set` would grow with the attempt count. A newer hash evicts whatever held its bucket, so a duplicate can go unreported after eviction; the error re-evaluates, it never skips something unseen. Zero marks an empty bucket, so a zero hash is never reported present.
package struct RecentHashTable {
    private var slots: [UInt64]
    private let mask: Int

    package init(capacityExponent: Int) {
        slots = Array(repeating: 0, count: 1 << capacityExponent)
        mask = slots.count - 1
    }

    /// Records `hash` and returns whether it already held its bucket. The index comes from the high bits so that a low-bit collision is not also an index collision.
    package mutating func insertReportingPresence(_ hash: UInt64) -> Bool {
        let index = Int(truncatingIfNeeded: hash >> 24) & mask
        let wasPresent = slots[index] == hash && hash != 0
        slots[index] = hash
        return wasPresent
    }
}
