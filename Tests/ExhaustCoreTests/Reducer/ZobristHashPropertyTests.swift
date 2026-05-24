import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("ZobristHash Properties")
struct ZobristHashPropertyTests {
    private static let valueEntryGen: Generator<ChoiceSequenceValue> = Gen.zip(
        Gen.choose(in: UInt64(0) ... 1000),
        Gen.pick(choices: [
            (weight: UInt64(2), generator: Gen.just(TypeTag.uint64)),
            (weight: UInt64(2), generator: Gen.just(TypeTag.int64)),
            (weight: UInt64(1), generator: Gen.just(TypeTag.double)),
        ])
    ).map { (pair: (UInt64, TypeTag)) in
        ChoiceSequenceValue.value(
            .init(choice: ChoiceValue(pair.0, tag: pair.1), validRange: 0 ... 1000)
        )
    }

    private static let sequenceGen: Generator<ChoiceSequence> =
        Gen.arrayOf(valueEntryGen, within: 1 ... 10).map { (entries: [ChoiceSequenceValue]) in
            var sequence = ChoiceSequence()
            for entry in entries {
                sequence.append(entry)
            }
            return sequence
        }

    @Test("Incremental hash equals full recomputation after single-element changes")
    func incrementalMatchesFull() throws {
        let gen = Gen.zip(
            Self.sequenceGen,
            Gen.choose(in: UInt64(0) ... 1000),
            Gen.pick(choices: [
                (weight: UInt64(1), generator: Gen.just(TypeTag.uint64)),
                (weight: UInt64(1), generator: Gen.just(TypeTag.int64)),
            ])
        ).map { (outer: (ChoiceSequence, UInt64, TypeTag)) in
            (outer.0, outer.1, outer.2)
        }

        try exhaustCheck(gen, maxIterations: 300) { base, newBitPattern, tag in
            let baseHash = ZobristHash.hash(of: base)
            var probe = base
            let modIndex = Int(newBitPattern % UInt64(probe.count))
            probe[modIndex] = .value(.init(choice: ChoiceValue(newBitPattern, tag: tag), validRange: 0 ... 1000))
            let incremental = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: base,
                probe: probe
            )
            let full = ZobristHash.hash(of: probe)
            return incremental == full
        }
    }

    @Test("Incremental hash equals full recomputation after length changes")
    func incrementalMatchesFullLengthChange() throws {
        let gen = Gen.zip(Self.sequenceGen, Self.valueEntryGen)
        try exhaustCheck(gen, maxIterations: 300) { pair in
            let (base, extraEntry) = pair
            let baseHash = ZobristHash.hash(of: base)
            var longer = base
            longer.append(extraEntry)
            let incremental = ZobristHash.incrementalHash(
                baseHash: baseHash,
                baseSequence: base,
                probe: longer
            )
            let full = ZobristHash.hash(of: longer)
            return incremental == full
        }
    }

    @Test("Hash is position-dependent: same values at different positions produce different hashes")
    func positionDependence() throws {
        let gen = Gen.zip(
            Self.valueEntryGen,
            Gen.choose(in: UInt64(2) ... 8)
        ).map { (pair: (ChoiceSequenceValue, UInt64)) in
            (pair.0, Int(pair.1))
        }

        try exhaustCheck(gen, maxIterations: 200) { entry, length in
            var seqA = ChoiceSequence()
            var seqB = ChoiceSequence()
            let filler = ChoiceSequenceValue.value(
                .init(choice: ChoiceValue(0 as UInt64, tag: .uint64), validRange: 0 ... 1000)
            )
            for i in 0 ..< length {
                seqA.append(i == 0 ? entry : filler)
                seqB.append(i == length - 1 ? entry : filler)
            }
            if entry == filler { return true }
            return ZobristHash.hash(of: seqA) != ZobristHash.hash(of: seqB)
        }
    }
}
