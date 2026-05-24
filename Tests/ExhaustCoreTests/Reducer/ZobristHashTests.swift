import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ZobristHash")
struct ZobristHashTests {
    // MARK: - Basic Properties

    @Test("Identical sequences produce identical hashes")
    func identicalSequencesIdenticalHashes() {
        let sequence = GraphFixture(.uint64Zip([42, 99], in: 0 ... 100)).sequence
        #expect(ZobristHash.hash(of: sequence) == ZobristHash.hash(of: sequence))
    }

    @Test("Different sequences produce different hashes")
    func differentSequencesDifferentHashes() {
        let hash1 = ZobristHash.hash(of: GraphFixture(.uint64(42, in: 0 ... 100)).sequence)
        let hash2 = ZobristHash.hash(of: GraphFixture(.uint64(43, in: 0 ... 100)).sequence)
        #expect(hash1 != hash2)
    }

    @Test("Position matters: swapped elements produce different hashes")
    func positionDependence() {
        let hash1 = ZobristHash.hash(of: GraphFixture(.uint64Zip([1, 2], in: 0 ... 100)).sequence)
        let hash2 = ZobristHash.hash(of: GraphFixture(.uint64Zip([2, 1], in: 0 ... 100)).sequence)
        #expect(hash1 != hash2)
    }

    // MARK: - Incremental Hash

    @Test("Incremental hash matches full hash when no changes")
    func incrementalNoChanges() {
        let sequence = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).sequence
        let baseHash = ZobristHash.hash(of: sequence)
        let incrementalResult = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: sequence,
            probe: sequence
        )
        #expect(incrementalResult == baseHash)
    }

    @Test("Incremental hash matches full hash after single element change")
    func incrementalSingleChange() {
        let base = GraphFixture(.uint64Zip([10, 20], in: 0 ... 100)).sequence
        let probe = GraphFixture(.uint64Zip([10, 99], in: 0 ... 100)).sequence
        let baseHash = ZobristHash.hash(of: base)
        let expectedHash = ZobristHash.hash(of: probe)
        let incrementalResult = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: base,
            probe: probe
        )
        #expect(incrementalResult == expectedHash)
    }

    @Test("Incremental hash handles different-length sequences")
    func incrementalDifferentLengths() {
        let base = GraphFixture(.uint64Sequence([1, 2], in: 0 ... 100)).sequence
        let probe = GraphFixture(.uint64Sequence([1], in: 0 ... 100)).sequence
        let baseHash = ZobristHash.hash(of: base)
        let expectedHash = ZobristHash.hash(of: probe)
        let incrementalResult = ZobristHash.incrementalHash(
            baseHash: baseHash,
            baseSequence: base,
            probe: probe
        )
        #expect(incrementalResult == expectedHash)
    }

    // MARK: - Contribution

    @Test("Same value at different positions produces different contributions")
    func contributionPositionDependence() {
        let value = ChoiceSequenceValue.value(.init(
            choice: ChoiceValue(42 as UInt64, tag: .uint64),
            validRange: 0 ... 100,
            isRangeExplicit: true
        ))
        let contribution0 = ZobristHash.contribution(at: 0, value)
        let contribution1 = ZobristHash.contribution(at: 1, value)
        #expect(contribution0 != contribution1)
    }
}
