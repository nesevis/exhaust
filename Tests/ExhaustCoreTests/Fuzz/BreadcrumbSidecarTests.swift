import Foundation
import Testing
@testable import ExhaustCore

/// The sidecar's crash consistency: a process killed partway through a record must never hand the next run a blend of two candidates.
@Suite("Breadcrumb sidecar")
struct BreadcrumbSidecarTests {
    @Test("The candidate sequence round-trips")
    func sequenceRoundTrips() throws {
        try withBreadcrumb { breadcrumb, url in
            let sequence = choiceSequence(of: 12)
            breadcrumb.record(candidateHash: 7, kind: .reduction, sequence: sequence)
            let survivor = try #require(FuzzBreadcrumb.readSurvivor(fileURL: url))
            #expect(survivor.candidateSequence == sequence)
            #expect(survivor.kind == .reduction)
        }
    }

    @Test("Recording the candidate follows the campaign budget")
    func recordingFollowsBudget() {
        let floor = FuzzTunables.trapCandidateBudgetFloor
        // Short runs are cheap to reproduce by running them again, so they do not pay for the recording.
        #expect(FuzzRunnerConfiguration(budgetNanoseconds: floor - 1, seed: 1).recordsTrapCandidate == false)
        #expect(FuzzRunnerConfiguration(budgetNanoseconds: floor, seed: 1).recordsTrapCandidate)
        #expect(FuzzRunnerConfiguration(budgetNanoseconds: floor * 6, seed: 1).recordsTrapCandidate)
    }

    @Test("Without the opt-in the slot carries hashes and a kind, and no sequence")
    func sequenceIsOmittedByDefault() throws {
        try withBreadcrumb(recordsCandidateSequence: false) { breadcrumb, url in
            breadcrumb.record(candidateHash: 7, parentHash: 8, kind: .reduction, sequence: choiceSequence(of: 12))
            let survivor = try #require(FuzzBreadcrumb.readSurvivor(fileURL: url))
            // The hashes are what quarantine a parent and identify the probe; only the input itself costs per-invocation work to store.
            #expect(survivor.candidateHash == 7)
            #expect(survivor.parentHash == 8)
            #expect(survivor.kind == .reduction)
            #expect(survivor.candidateSequence == nil)
        }
    }

    @Test("A candidate past the cap is recorded as unavailable, never as a prefix")
    func oversizedCandidateIsUnavailable() throws {
        try withBreadcrumb { breadcrumb, url in
            // A prefix of a choice sequence is a different input; offering one as the counterexample would be worse than admitting the size.
            let sequence = choiceSequence(of: FuzzBreadcrumb.payloadCapacity)
            breadcrumb.record(candidateHash: 9, kind: .search, sequence: sequence)
            let survivor = try #require(FuzzBreadcrumb.readSurvivor(fileURL: url))
            #expect(survivor.candidateHash == 9)
            #expect(survivor.candidateSequence == nil)
        }
    }

    @Test("A torn slot loses to the intact one it was overwriting")
    func tornSlotFallsBackToItsPredecessor() throws {
        try withBreadcrumb { breadcrumb, url in
            let first = choiceSequence(of: 4)
            breadcrumb.record(candidateHash: 1, kind: .search, sequence: first)
            breadcrumb.record(candidateHash: 2, kind: .search, sequence: choiceSequence(of: 6))

            // Corrupt whichever slot holds the newer record, one field boundary at a time. The older record is still intact in the other slot, and that is what a resumed run must read.
            for offset in [0, 8, 16, 24, 32, 36, 40, 48, 60] {
                let bytes = breadcrumb.mappedBytes()
                let newer = newerSlotIndex(in: bytes)
                let byteOffset = newer * FuzzBreadcrumb.slotSize + offset
                let original = bytes[byteOffset]
                breadcrumb.corruptByte(at: byteOffset, with: original ^ 0xFF)

                let survivor = try #require(
                    FuzzBreadcrumb.readSurvivor(fileURL: url),
                    "corrupting byte \(offset) of the newer slot lost the older record too"
                )
                #expect(survivor.candidateHash == 1, "byte \(offset)")
                #expect(survivor.candidateSequence == first, "byte \(offset)")
            }
        }
    }

    @Test("A stale commit marker over a half-written payload is rejected")
    func staleMarkerOverHalfWrittenPayloadIsRejected() throws {
        try withBreadcrumb { breadcrumb, url in
            breadcrumb.record(candidateHash: 1, kind: .search, sequence: choiceSequence(of: 4))
            breadcrumb.record(candidateHash: 2, kind: .search, sequence: choiceSequence(of: 6))

            // The marker survives from the last complete write while the payload beneath it is half of the next one. Only the checksum catches this, which is why the length and the marker are not enough on their own.
            let bytes = breadcrumb.mappedBytes()
            let newer = newerSlotIndex(in: bytes)
            let tailOffset = newer * FuzzBreadcrumb.slotSize + FuzzBreadcrumb.slotSize - 1
            let midOffset = newer * FuzzBreadcrumb.slotSize + 50
            breadcrumb.corruptByte(at: tailOffset, with: bytes[tailOffset] ^ 0xFF)
            breadcrumb.corruptByte(at: midOffset, with: bytes[midOffset] ^ 0xFF)

            let survivor = try #require(FuzzBreadcrumb.readSurvivor(fileURL: url))
            #expect(survivor.candidateHash == 1)
        }
    }

    @Test("A cleared breadcrumb reads as nothing in flight")
    func clearedBreadcrumbIsEmpty() throws {
        try withBreadcrumb { breadcrumb, url in
            breadcrumb.record(candidateHash: 5, kind: .search, sequence: choiceSequence(of: 3))
            breadcrumb.clear()
            #expect(FuzzBreadcrumb.readSurvivor(fileURL: url) == nil)
        }
    }
}

// MARK: - Helpers

/// Opens a breadcrumb over a scratch file, opted into storing candidate sequences, which is what the slot-layout tests are about. The process-wide default is off.
private func withBreadcrumb(
    recordsCandidateSequence: Bool = true,
    _ body: (FuzzBreadcrumb, URL) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("breadcrumb.bin")
    try body(#require(FuzzBreadcrumb(fileURL: url, recordsCandidateSequence: recordsCandidateSequence)), url)
}

/// Which slot holds the higher generation, so a test can corrupt the record that was most recently written.
private func newerSlotIndex(in bytes: [UInt8]) -> Int {
    func generation(_ slot: Int) -> UInt64 {
        bytes.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: slot * FuzzBreadcrumb.slotSize + 8, as: UInt64.self))
        }
    }
    return generation(0) >= generation(1) ? 0 : 1
}

private func choiceSequence(of count: Int) -> ChoiceSequence {
    ChoiceSequence((0 ..< count).map { index in
        .value(ChoiceSequenceValue.Value(
            choice: ChoiceValue(UInt64(index), tag: .int),
            validRange: 0 ... 1000,
            isRangeExplicit: true
        ))
    })
}
