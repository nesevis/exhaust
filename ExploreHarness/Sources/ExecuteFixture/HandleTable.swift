// The entity-reference producer/consumer archetype (matrix fixture MX1b, "HandleTable"): consumers precondition-skip without producers, so mutation and masking policies' skip-rate behavior becomes measurable here — the execute design doc's precondition-starvation wrinkle, as an observable.
//
// ## Shape Coordinates
//
// Trigger class: entity-reference producer/consumer chain. Coverage surface: not flatness-claiming (slot scans branch on occupancy). Vocabulary: four commands, uniform weight, skip-heavy by construction. Argument domains: slot 0...7 and value 0...9. Length scale: minimal trigger is 6 commands, far inside the limit.
//
// ## Ground-Truth Registry
//
// Fault E (stale handle after compaction):
//     Trigger: a write resolved through a handle whose generation predates a compact that relocated >= 2 entries (per-slot `lastBumpRelocations` carries the relocation count of the compact that invalidated the slot's outstanding handles; create/destroy bumps reset it to 0, so destroy-then-recreate staleness never fires E).
//     Trigger variable: lastBumpRelocations[handle.slot] at a stale write.
//     Minimal: [create, create, create, destroy(first), compact, write(stale)] — destroying slot 0 leaves entries at slots 1 and 2, compact relocates both, and a write through either surviving original handle is stale with relocation count 2.
//     Effect: throws HandleTableError.corruption.
//
// Single planted fault; benign stale writes and stale destroys are silent no-ops by design, so no other failure channel exists.
//
// ## Blind Rate (deliberately probable)
//
// Monte Carlo over uniform spec-shaped sequences (lengths 0...40): fault E fires in ~7.6% of attempts, so the baseline finds it in effectively every seed. E is a regression-detection fault (the >= 18/20 side of the calibration window); the fixture's differential observable is the skip fraction (~20% blind), recorded by the spec, not the fault rate.
//
// Pinned baseline (MX1g, 2026-07-12, seeds 1-20, 10 s, defaults, .commandLimit(40)): 20/20, median skip fraction 0.025.

/// A fixed-capacity table of generation-counted handles. Compaction relocates live entries and invalidates outstanding handles — the classic stale-reference shape.
public struct HandleTable: Sendable {
    /// A client-held reference to a table entry, valid until the entry is destroyed or relocated.
    public struct Handle: Sendable, Equatable {
        public let slot: Int
        public let generation: Int
    }

    /// The fixed slot count.
    public static let capacity = 8

    private var occupied = [Bool](repeating: false, count: HandleTable.capacity)
    private var generations = [Int](repeating: 0, count: HandleTable.capacity)
    private var storedValues = [Int](repeating: 0, count: HandleTable.capacity)

    /// Fault E trigger variable: the relocation count of the compact that last bumped each slot's generation; 0 when the bump came from create or destroy.
    private var lastBumpRelocations = [Int](repeating: 0, count: HandleTable.capacity)

    public init() {}

    public var occupiedCount: Int {
        occupied.lazy.count(where: { $0 })
    }

    public var isFull: Bool {
        occupiedCount >= Self.capacity
    }

    public var isEmpty: Bool {
        occupiedCount == 0
    }

    // MARK: - Commands

    /// Claims the lowest free slot, or returns `nil` when the table is full.
    public mutating func create() -> Handle? {
        guard let slot = occupied.firstIndex(of: false) else {
            return nil
        }
        occupied[slot] = true
        storedValues[slot] = 0
        lastBumpRelocations[slot] = 0
        return Handle(slot: slot, generation: generations[slot])
    }

    /// Writes through a handle. Fresh handles write; stale handles are silent no-ops unless the staleness came from a compact that relocated at least two entries — fault E.
    public mutating func write(handle: Handle, value: Int) throws {
        if occupied[handle.slot], generations[handle.slot] == handle.generation {
            storedValues[handle.slot] = value
            return
        }
        // Fault E: the invalidating bump was a multi-entry compaction.
        if lastBumpRelocations[handle.slot] >= 2 {
            throw HandleTableError.corruption
        }
    }

    /// Frees the handle's entry. Stale handles are silent no-ops.
    public mutating func destroy(handle: Handle) {
        guard occupied[handle.slot], generations[handle.slot] == handle.generation else {
            return
        }
        occupied[handle.slot] = false
        generations[handle.slot] += 1
        lastBumpRelocations[handle.slot] = 0
    }

    /// Relocates live entries to the lowest slots in stable order, bumping generations on every touched slot. Outstanding handles to relocated entries become stale.
    public mutating func compact() {
        var moves: [(source: Int, destination: Int, value: Int)] = []
        var nextFree = 0
        for slot in 0 ..< Self.capacity where occupied[slot] {
            if slot != nextFree {
                moves.append((source: slot, destination: nextFree, value: storedValues[slot]))
            }
            nextFree += 1
        }
        let relocated = moves.count
        guard relocated > 0 else {
            return
        }
        for move in moves {
            occupied[move.source] = false
            occupied[move.destination] = true
            storedValues[move.destination] = move.value
        }
        // Destination bumps first (attribution 0), then source bumps carrying the relocation count: a slot that is both keeps the source attribution, because the outstanding live handle pointed at the source role.
        for move in moves {
            generations[move.destination] += 1
            lastBumpRelocations[move.destination] = 0
        }
        for move in moves {
            generations[move.source] += 1
            lastBumpRelocations[move.source] = relocated
        }
    }
}

public enum HandleTableError: Error, Equatable, Sendable {
    case corruption
}
