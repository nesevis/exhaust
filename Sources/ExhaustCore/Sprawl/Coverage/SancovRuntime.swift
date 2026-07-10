// SanitizerCoverage runtime hooks and region registry for coverage-guided exploration.
//
// Instrumented targets built with `-sanitize-coverage=edge,inline-8bit-counters,pc-table` emit
// startup calls to `__sanitizer_cov_8bit_counters_init` and `__sanitizer_cov_pcs_init`. Defining
// those symbols here (via @_cdecl) makes ExhaustCore the receiver: the counter and PC-table
// regions of every instrumented image land in this registry before any test code runs.

import Foundation

/// Process-global registry of SanitizerCoverage counter and PC-table regions.
///
/// The init callbacks fire once per instrumented image (the spike measured two registrations for a single statically linked test binary), so regions accumulate rather than overwrite. Registration happens during image loading, before tests run; after startup the region list is effectively immutable. Readers snapshot the region arrays once (see ``SancovCoverageSource``) and then operate lock-free on the raw pointers, which stay valid for the process lifetime because the regions live in the images' data segments.
///
/// Edge indices are global: regions are concatenated in registration order, and an edge's index is its region's running offset plus its position within the region. The PC table uses the same indexing, which is what lets report-time symbolisation resolve a counter index to a source location.
package enum SancovRuntime {
    /// One instrumented image's inline 8-bit counter array.
    package struct CounterRegion: @unchecked Sendable {
        /// Base of the counter array inside the image's data segment.
        package let base: UnsafeMutablePointer<UInt8>
        /// Number of edges (one byte each) in this region.
        package let count: Int
        /// Global index of this region's first edge.
        package let globalOffset: Int
    }

    /// One entry of the PC table: the edge's program counter and its flags word.
    package struct PCTableEntry: Sendable {
        /// The program counter of the edge's first instruction.
        package let programCounter: UInt
        /// Raw flags; bit 0 set marks a function entry edge.
        package let flags: UInt

        /// Whether this edge is a function entry point rather than an interior edge.
        package var isFunctionEntry: Bool {
            flags & 1 == 1
        }
    }

    /// One instrumented image's PC-table slice, parallel to its counter region.
    ///
    /// Entries are read as raw `UInt` word pairs rather than through a Swift struct overlay, because Swift does not guarantee C-compatible layout for its own structs.
    package struct PCTableRegion: @unchecked Sendable {
        /// First word of the image's PC table; entry `i` occupies words `2i` (program counter) and `2i + 1` (flags).
        package let base: UnsafePointer<UInt>
        /// Number of entries; matches the paired counter region's edge count.
        package let count: Int

        /// The entry at the given position within this region.
        package func entry(at index: Int) -> PCTableEntry {
            PCTableEntry(programCounter: base[index * 2], flags: base[index * 2 + 1])
        }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var counterRegions: [CounterRegion] = []
    private nonisolated(unsafe) static var pcTableRegions: [PCTableRegion] = []

    // MARK: - Registration (called from the @_cdecl hooks)

    /// Registers an inline 8-bit counter region. Idempotent per base address, because the callback can fire more than once for the same image.
    package static func registerCounters(start: UnsafeMutablePointer<UInt8>, end: UnsafeMutablePointer<UInt8>) {
        let count = start.distance(to: end)
        guard count > 0 else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard counterRegions.contains(where: { $0.base == start }) == false else {
            return
        }
        let offset = counterRegions.reduce(0) { $0 + $1.count }
        counterRegions.append(CounterRegion(base: start, count: count, globalOffset: offset))
    }

    /// Registers a PC-table region. Idempotent per base address.
    package static func registerPCTable(start: UnsafeRawPointer, end: UnsafeRawPointer) {
        // Entries are (pc, flags) uintptr_t pairs, two words per entry.
        let byteCount = start.distance(to: end)
        let entryCount = byteCount / (MemoryLayout<UInt>.stride * 2)
        guard entryCount > 0 else {
            return
        }
        let typedBase = start.assumingMemoryBound(to: UInt.self)
        lock.lock()
        defer { lock.unlock() }
        guard pcTableRegions.contains(where: { $0.base == typedBase }) == false else {
            return
        }
        pcTableRegions.append(PCTableRegion(base: typedBase, count: entryCount))
    }

    // MARK: - Reading

    /// Whether any instrumented image registered a counter region. False means the build lacks `-sanitize-coverage` flags and `#explore(time:)` must fail loudly.
    package static var isInstrumented: Bool {
        lock.lock()
        defer { lock.unlock() }
        return counterRegions.isEmpty == false
    }

    /// The total number of instrumented edges across all registered regions.
    package static var edgeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return counterRegions.reduce(0) { $0 + $1.count }
    }

    /// A stable snapshot of the registered counter regions.
    package static func currentCounterRegions() -> [CounterRegion] {
        lock.lock()
        defer { lock.unlock() }
        return counterRegions
    }

    /// A stable snapshot of the registered PC-table regions.
    package static func currentPCTableRegions() -> [PCTableRegion] {
        lock.lock()
        defer { lock.unlock() }
        return pcTableRegions
    }

    /// Resolves a global edge index to its PC-table entry, or nil when the build omitted `pc-table` or the index is out of range.
    package static func pcTableEntry(forEdge globalIndex: Int) -> PCTableEntry? {
        let regions = currentPCTableRegions()
        var remaining = globalIndex
        guard remaining >= 0 else {
            return nil
        }
        for region in regions {
            if remaining < region.count {
                return region.entry(at: remaining)
            }
            remaining -= region.count
        }
        return nil
    }

    // MARK: - Test Support

    /// Removes all registered regions so tests can register synthetic ones without cross-test bleed. Never called on the production path.
    package static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        counterRegions = []
        pcTableRegions = []
    }
}

// MARK: - SanitizerCoverage Hooks

// These must be free functions with exact C symbol names; the instrumented images' module
// constructors call them during image loading. Bodies must stay minimal and allocation-light:
// they run before main, potentially before any other Swift code.

@_cdecl("__sanitizer_cov_8bit_counters_init")
func exhaustSancovCountersInit(_ start: UnsafeMutablePointer<UInt8>?, _ end: UnsafeMutablePointer<UInt8>?) {
    guard let start, let end else {
        return
    }
    SancovRuntime.registerCounters(start: start, end: end)
}

@_cdecl("__sanitizer_cov_pcs_init")
func exhaustSancovPCsInit(_ start: UnsafeRawPointer?, _ end: UnsafeRawPointer?) {
    guard let start, let end else {
        return
    }
    SancovRuntime.registerPCTable(start: start, end: end)
}
