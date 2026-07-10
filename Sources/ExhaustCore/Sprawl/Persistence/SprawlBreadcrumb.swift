// The per-invocation breadcrumb: which candidate was being evaluated when the process died.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A memory-mapped 16-byte slot recording the candidate under evaluation, written before every property invocation.
///
/// The write is a plain store to a dirty mmap page — no syscall, no fsync. A Swift trap kills the process, but the kernel still flushes the page before releasing the inode, so the breadcrumb survives any application-level crash; only kernel panic or hard power loss loses it. The slot holds the candidate's Zobrist hash and its mutation parent's hash (0 outside sprawl): the candidate itself usually died before corpus admission, so the parent — which is in the snapshot — is what resume can look up and quarantine.
package final class SprawlBreadcrumb: @unchecked Sendable {
    // @unchecked: the mapping is created once at init and only the owning loop thread writes it.
    private let mapping: UnsafeMutableRawPointer
    private let fileDescriptor: Int32

    /// Slot layout: candidate hash at offset 0, parent hash at offset 8.
    package static let slotSize = 16

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

    /// Records the candidate about to be evaluated. Called on the loop thread before every property invocation.
    package func record(candidateHash: UInt64, parentHash: UInt64) {
        mapping.storeBytes(of: candidateHash.littleEndian, toByteOffset: 0, as: UInt64.self)
        mapping.storeBytes(of: parentHash.littleEndian, toByteOffset: 8, as: UInt64.self)
    }

    /// Clears the slot. Called after a run completes normally so a later resume does not misread a survived evaluation as a trap.
    package func clear() {
        record(candidateHash: 0, parentHash: 0)
    }

    /// Reads a breadcrumb file without mapping it, for resume. Returns nil when the file is absent, short, or all zeros (no evaluation in flight at death).
    package static func readSurvivor(fileURL: URL) -> (candidateHash: UInt64, parentHash: UInt64)? {
        guard let data = try? Data(contentsOf: fileURL), data.count >= slotSize else {
            return nil
        }
        let candidate = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        let parent = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
        guard candidate != 0 else {
            return nil
        }
        return (candidate, parent)
    }
}
