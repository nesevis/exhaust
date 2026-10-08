// The per-invocation breadcrumb: which candidate was being evaluated when the process died.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
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

/// A memory-mapped record of the probe under evaluation, written before every property invocation and cleared after it returns.
///
/// The write is a plain store to a dirty mmap page: no syscall, no fsync. A Swift trap kills the process, but the kernel still flushes the page before releasing the inode, so the breadcrumb survives any application-level crash; only kernel panic or hard power loss loses it.
///
/// Each record carries the probe's Zobrist hash, its mutation parent's hash (0 outside the mutation phase), which kind of probe it was, and, when `recordsCandidateSequence` is on, the candidate's own choice sequence. The hashes and the kind decide what a resumed run quarantines and how it describes the death; the sequence is what lets it show the user the input, which a hash cannot, and it is budget-gated because writing it costs throughput on every probe (see ``FuzzTunables/trapCandidateBudgetFloor``).
///
/// ## Why two slots
///
/// A multi-word payload cannot be overwritten atomically, so a process killed mid-write would otherwise leave a blend of two candidates with nothing downstream able to tell. Writes alternate between two slots and publish a commit marker last, so the previous candidate stays intact and readable while the next one is written, and a torn slot fails its marker or its checksum and is ignored in favour of the other.
package final class FuzzBreadcrumb: @unchecked Sendable {
    // @unchecked: the mapping is created once at init and only the owning loop thread writes it.
    private let mapping: UnsafeMutableRawPointer
    #if canImport(Darwin) || canImport(Glibc)
        private let fileDescriptor: Int32
    #elseif canImport(WinSDK)
        private let fileHandle: UnsafeMutableRawPointer
        private let mappingHandle: UnsafeMutableRawPointer
    #endif

    /// Rises on every record, so a reader can tell which of the two slots is the newer.
    private var generation: UInt64 = 0

    /// The slot the next record writes. Alternates, so the newest committed slot survives intact while its successor is written.
    private var writeSlotIndex = 0

    /// Whether ``record(candidateHash:parentHash:kind:sequence:)`` stores the sequence it is handed. Off leaves every slot's payload empty, so a survivor carries hashes and a kind and no input.
    private let recordsCandidateSequence: Bool

    /// The largest choice sequence a slot can hold. A candidate whose encoding exceeds this is recorded as present but unavailable, never as a prefix: a truncated sequence is a different input, and offering one as the counterexample would be worse than admitting the size.
    package static let payloadCapacity = 4096

    // MARK: - Slot Layout

    ///
    /// Two slots, each `slotSize` bytes:
    ///
    ///   0   u64  commit marker (`slotCommitted` once the rest of the slot is written, 0 while writing)
    ///   8   u64  generation, so the reader can tell which slot is newer
    ///   16  u64  candidate hash
    ///   24  u64  parent hash
    ///   32  u32  probe kind
    ///   36  u32  payload length in bytes (0 when the candidate exceeded the cap)
    ///   40  u32  FNV-1a checksum over the payload
    ///   44  u32  reserved
    ///   48       payload
    ///
    /// A cleared slot is all zeros, so `readSurvivor` treats a zero candidate hash as "nothing in flight" exactly as the 16-byte layout did.
    package static let slotSize = 48 + payloadCapacity

    /// Total mapped size: both slots.
    package static let mappingSize = slotSize * 2

    /// Written into a slot's first word once every other field is in place.
    private static let slotCommitted: UInt64 = 0x4558_4855_5354_4331 // "EXHUSTC1"

    private static let candidateHashOffset = 16
    private static let parentHashOffset = 24
    private static let kindOffset = 32
    private static let payloadLengthOffset = 36
    private static let checksumOffset = 40
    private static let payloadOffset = 48

    /// Opens (creating if needed) and maps the breadcrumb file, or returns nil when the platform lacks mmap or the file cannot be created.
    ///
    /// - Parameter recordsCandidateSequence: Whether to store each candidate's sequence in its slot. Callers derive it from the run's budget through ``FuzzRunnerConfiguration/recordsTrapCandidate``; there is no default, because a caller that has not thought about the cost should not be silently paying it.
    package init?(fileURL: URL, recordsCandidateSequence: Bool) {
        self.recordsCandidateSequence = recordsCandidateSequence
        #if canImport(Darwin) || canImport(Glibc)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let descriptor = open(fileURL.path, O_RDWR | O_CREAT, 0o644)
            guard descriptor >= 0 else {
                return nil
            }
            guard ftruncate(descriptor, off_t(Self.mappingSize)) == 0 else {
                close(descriptor)
                return nil
            }
            guard let mapped = mmap(nil, Self.mappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
                  mapped != MAP_FAILED
            else {
                close(descriptor)
                return nil
            }
            mapping = mapped
            fileDescriptor = descriptor
        #elseif canImport(WinSDK)
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var filePath = fileURL.path
            if filePath.first == "/", filePath.dropFirst(2).first == ":" {
                filePath.removeFirst()
            }
            let rawHandle: UnsafeMutableRawPointer? = filePath.withCString(encodedAs: UTF16.self) { widePath in
                CreateFileW(
                    widePath,
                    DWORD(0x8000_0000) | DWORD(0x4000_0000),
                    DWORD(0x0000_0001) | DWORD(0x0000_0002),
                    nil,
                    DWORD(4),
                    DWORD(0x80),
                    nil
                )
            }
            guard let hFile = rawHandle, hFile != INVALID_HANDLE_VALUE else {
                return nil
            }
            let rawMapping: UnsafeMutableRawPointer? = CreateFileMappingW(
                hFile,
                nil,
                DWORD(0x04),
                0,
                DWORD(Self.mappingSize),
                nil
            )
            guard let hMapping = rawMapping else {
                CloseHandle(hFile)
                return nil
            }
            let rawView: UnsafeMutableRawPointer? = MapViewOfFile(
                hMapping,
                DWORD(0x02),
                0, 0,
                SIZE_T(Self.mappingSize)
            )
            guard let mapped = rawView else {
                CloseHandle(hMapping)
                CloseHandle(hFile)
                return nil
            }
            mapping = mapped
            fileHandle = hFile
            mappingHandle = hMapping
        #else
            return nil
        #endif
    }

    deinit {
        #if canImport(Darwin) || canImport(Glibc)
            munmap(mapping, Self.mappingSize)
            close(fileDescriptor)
        #elseif canImport(WinSDK)
            UnmapViewOfFile(mapping)
            CloseHandle(mappingHandle)
            CloseHandle(fileHandle)
        #endif
    }

    /// Marks a slot occupied for exactly the span of `evaluate`, clearing it on every exit path.
    ///
    /// The span is the property invocation rather than any wider bracket, because an occupied slot means "an abnormal termination here is this input's fault". A slot still occupied through a caller's own teardown names a probe that already returned, and the next run reports a trap that never happened and quarantines that input.
    package func marking<Result>(
        candidateHash: UInt64,
        parentHash: UInt64 = 0,
        kind: FuzzProbeKind,
        sequence: ChoiceSequence? = nil,
        _ evaluate: () -> Result
    ) -> Result {
        record(candidateHash: candidateHash, parentHash: parentHash, kind: kind, sequence: sequence)
        defer { clear() }
        return evaluate()
    }

    /// Records the probe about to be evaluated. Called on the loop thread before every property invocation.
    ///
    /// Writes the slot that is not currently the newest, so the newest stays intact and readable until this one is complete. The commit marker goes down last: until it does, a reader rejects the slot and takes the other, which is what makes a process death partway through this harmless rather than a blend of two candidates.
    package func record(
        candidateHash: UInt64,
        parentHash: UInt64 = 0,
        kind: FuzzProbeKind,
        sequence: ChoiceSequence? = nil
    ) {
        var payload: [UInt8] = []
        if recordsCandidateSequence, let sequence {
            payload = ChoiceSequenceCodec.encodeBytes(sequence)
        }
        // Over the cap the candidate is recorded as present but unavailable rather than truncated: a prefix is a different input.
        let storedPayload = payload.count <= Self.payloadCapacity ? payload : []

        generation &+= 1
        let slot = mapping.advanced(by: writeSlotIndex * Self.slotSize)
        writeSlotIndex = 1 - writeSlotIndex

        slot.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
        slot.storeBytes(of: generation.littleEndian, toByteOffset: 8, as: UInt64.self)
        slot.storeBytes(of: candidateHash.littleEndian, toByteOffset: Self.candidateHashOffset, as: UInt64.self)
        slot.storeBytes(of: parentHash.littleEndian, toByteOffset: Self.parentHashOffset, as: UInt64.self)
        slot.storeBytes(of: UInt32(kind.rawValue).littleEndian, toByteOffset: Self.kindOffset, as: UInt32.self)
        slot.storeBytes(of: UInt32(storedPayload.count).littleEndian, toByteOffset: Self.payloadLengthOffset, as: UInt32.self)
        slot.storeBytes(of: Self.checksum(of: storedPayload).littleEndian, toByteOffset: Self.checksumOffset, as: UInt32.self)
        if storedPayload.isEmpty == false {
            storedPayload.withUnsafeBytes { source in
                slot.advanced(by: Self.payloadOffset).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        slot.storeBytes(of: Self.slotCommitted.littleEndian, toByteOffset: 0, as: UInt64.self)
    }

    /// Clears both slots. Called after every property invocation returns, and after a run completes, so a later resume does not misread a survived evaluation as a trap.
    package func clear() {
        for index in 0 ..< 2 {
            mapping.advanced(by: index * Self.slotSize)
                .storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
            mapping.advanced(by: index * Self.slotSize)
                .storeBytes(of: UInt64(0), toByteOffset: Self.candidateHashOffset, as: UInt64.self)
        }
    }

    /// Reads the raw mapped bytes as a contiguous array.
    package func mappedBytes() -> [UInt8] {
        [UInt8](UnsafeBufferPointer(start: mapping.assumingMemoryBound(to: UInt8.self), count: Self.mappingSize))
    }

    /// Writes `byte` at `offset` in the mapping. Intended for crash-corruption tests that simulate torn writes.
    package func corruptByte(at offset: Int, with byte: UInt8) {
        mapping.storeBytes(of: byte, toByteOffset: offset, as: UInt8.self)
    }

    /// FNV-1a over the payload, so a slot torn partway through its bytes fails to validate even when its length and marker survived.
    private static func checksum(of payload: [UInt8]) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in payload {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// Reads a breadcrumb file without mapping it, for resume. Returns nil when the file is absent, short, or holds no committed slot with a candidate.
    ///
    /// Takes the higher generation among slots that validate: a slot passes only when its commit marker is present, its payload length is within the cap, and its checksum matches. A slot torn by a process death fails one of those and loses to its predecessor.
    package static func readSurvivor(fileURL: URL) -> Survivor? {
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        let bytes = [UInt8](data)
        var best: Survivor?
        var bestGeneration: UInt64 = 0
        for index in 0 ..< 2 {
            guard let candidate = survivor(in: bytes, slotIndex: index), candidate.generation >= bestGeneration else {
                continue
            }
            best = candidate
            bestGeneration = candidate.generation
        }
        return best
    }

    /// One slot's contents when it validates, or nil when it is empty, torn, or was never committed.
    private static func survivor(in bytes: [UInt8], slotIndex: Int) -> Survivor? {
        let base = slotIndex * slotSize
        guard bytes.count >= base + payloadOffset else {
            return nil
        }
        func word(_ offset: Int) -> UInt64 {
            bytes.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: base + offset, as: UInt64.self)) }
        }
        func half(_ offset: Int) -> UInt32 {
            bytes.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: base + offset, as: UInt32.self)) }
        }
        guard word(0) == slotCommitted else {
            return nil
        }
        let candidateHash = word(candidateHashOffset)
        guard candidateHash != 0 else {
            return nil
        }
        let length = Int(half(payloadLengthOffset))
        guard length <= payloadCapacity, bytes.count >= base + payloadOffset + length else {
            return nil
        }
        let payload = Array(bytes[(base + payloadOffset) ..< (base + payloadOffset + length)])
        guard checksum(of: payload) == half(checksumOffset) else {
            return nil
        }
        return Survivor(
            generation: word(8),
            candidateHash: candidateHash,
            parentHash: word(parentHashOffset),
            // An unrecognized kind reads as a search probe: a predecessor written by an older layout carries none, and misnaming the probe beats discarding a real crash marker.
            kind: FuzzProbeKind(rawValue: UInt64(half(kindOffset))) ?? .search,
            candidateSequence: length == 0 ? nil : ChoiceSequenceCodec.decodeBytes(payload)
        )
    }
}

/// What a crashed predecessor left in its breadcrumb.
package struct Survivor: Sendable {
    /// Rises with each record; the reader takes the highest that validates.
    package let generation: UInt64

    /// Zobrist hash of the candidate under evaluation.
    package let candidateHash: UInt64

    /// Hash of the candidate's mutation parent, or 0 outside the mutation phase.
    package let parentHash: UInt64

    /// Which of the run's probe kinds was executing.
    package let kind: FuzzProbeKind

    /// The candidate itself. Nil when it exceeded ``FuzzBreadcrumb/payloadCapacity`` or no longer decodes, in which case only the hash identifies it.
    package let candidateSequence: ChoiceSequence?
}
