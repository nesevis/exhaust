// The per-invocation breadcrumb: which candidate was being evaluated when the process died.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Which of the run's property invocations a breadcrumb slot belongs to.
///
/// Without this, every probe kind writes an indistinguishable slot and the resume diagnostic can only describe an abnormal termination as a search candidate's. Reduction is where a trap is most likely to surface, because it drives the property at inputs the search never produced.
package enum FuzzProbeKind: UInt64, Sendable {
    /// A search attempt: screening, sampling, or a mutation child.
    case search = 1
    /// A reduction probe, driving the property at a candidate derived from a failing input.
    case reduction = 2
    /// A normalization probe, driving the property at a bit-pattern variation of a reduced form.
    case normalization = 3
    /// The post-reduction classification re-run that yields a cluster's coverage signature.
    case classification = 4
    /// A restored entry or cluster re-judged against the current build at resume.
    case recovery = 5
}

/// A memory-mapped 24-byte slot recording the probe under evaluation, written before every property invocation and cleared after it returns.
///
/// The write is a plain store to a dirty mmap page — no syscall, no fsync. A Swift trap kills the process, but the kernel still flushes the page before releasing the inode, so the breadcrumb survives any application-level crash; only kernel panic or hard power loss loses it. The slot holds the probe's Zobrist hash, its mutation parent's hash (0 outside the mutation phase), and which kind of probe it was: the candidate itself usually died before corpus admission, so the parent — which is in the snapshot — is what resume can look up and quarantine, and the kind is what stops a reduction probe's death being reported and quarantined as a search candidate's.
package final class FuzzBreadcrumb: @unchecked Sendable {
    // @unchecked: the mapping is created once at init and only the owning loop thread writes it.
    private let mapping: UnsafeMutableRawPointer
    private let fileDescriptor: Int32

    /// Slot layout: candidate hash at offset 0, parent hash at offset 8, probe kind at offset 16.
    package static let slotSize = 24

    /// Opens (creating if needed) and maps the breadcrumb file, or returns nil when the platform lacks mmap or the file cannot be created.
    package init?(fileURL: URL) {
        #if canImport(Darwin) || canImport(Glibc)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
            guard descriptor >= 0 else {
                return nil
            }
            guard ftruncate(descriptor, off_t(Self.slotSize)) == 0 else {
                close(descriptor)
                return nil
            }
            guard let mapped = mmap(nil, Self.slotSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
                  mapped != MAP_FAILED
            else {
                close(descriptor)
                return nil
            }
            mapping = mapped
            fileDescriptor = descriptor
        #else
            return nil
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc)
            munmap(mapping, Self.slotSize)
            close(fileDescriptor)
        #endif
    }

    /// Records the probe about to be evaluated. Called on the loop thread before every property invocation.
    package func record(candidateHash: UInt64, parentHash: UInt64, kind: FuzzProbeKind) {
        // Parent and kind first, candidate last. The stores are not atomic together, and a process death between them (leaked concurrent work trapping; the loop thread itself runs no user code here) must not pair the new candidate with the previous slot's parent — resume would quarantine an unrelated corpus entry. The reversed tear pairs the previous, already-survived candidate with its successor's parent, which quarantines nothing that matters.
        mapping.storeBytes(of: parentHash.littleEndian, toByteOffset: 8, as: UInt64.self)
        mapping.storeBytes(of: kind.rawValue.littleEndian, toByteOffset: 16, as: UInt64.self)
        mapping.storeBytes(of: candidateHash.littleEndian, toByteOffset: 0, as: UInt64.self)
    }

    /// Marks the slot occupied for exactly the span of `evaluate`, clearing it on every exit path.
    ///
    /// The span is the property invocation rather than any wider bracket, because an occupied slot means "an abnormal termination here is this input's fault". A slot still occupied through a caller's own teardown names a probe that already returned, and the next run reports a trap that never happened and quarantines that input.
    package func marking<Result>(
        candidateHash: UInt64,
        parentHash: UInt64 = 0,
        kind: FuzzProbeKind,
        _ evaluate: () -> Result
    ) -> Result {
        record(candidateHash: candidateHash, parentHash: parentHash, kind: kind)
        defer { clear() }
        return evaluate()
    }

    /// Clears the slot. Called after every property invocation returns, and after a run completes, so a later resume does not misread a survived evaluation as a trap.
    package func clear() {
        mapping.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
        mapping.storeBytes(of: UInt64(0), toByteOffset: 8, as: UInt64.self)
        mapping.storeBytes(of: UInt64(0), toByteOffset: 16, as: UInt64.self)
    }

    /// Reads a breadcrumb file without mapping it, for resume. Returns nil when the file is absent, short, or all zeros (no evaluation in flight at death).
    ///
    /// An unrecognized kind word reads as ``FuzzProbeKind/search``: a predecessor written by an older layout has no kind at all, and misnaming the probe is better than discarding a real crash marker.
    package static func readSurvivor(fileURL: URL) -> (candidateHash: UInt64, parentHash: UInt64, kind: FuzzProbeKind)? {
        guard let data = try? Data(contentsOf: fileURL), data.count >= 16 else {
            return nil
        }
        let candidate = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        let parent = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        guard candidate != 0 else {
            return nil
        }
        let kindWord = data.count >= slotSize
            ? data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 16, as: UInt64.self)) }
            : 0
        return (candidate, parent, FuzzProbeKind(rawValue: kindWord) ?? .search)
    }
}
