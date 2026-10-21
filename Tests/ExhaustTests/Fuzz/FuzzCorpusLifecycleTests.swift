import Exhaust
import ExhaustCore
import Testing

@Suite("Fuzz corpus lifecycle contracts")
struct FuzzCorpusLifecycleTests {
    @Test("Admission, quarantine, resets, and parent selection agree with the model")
    func generatedLifecycle() async {
        await #execute(CorpusLifecycleSpec.self, mode: .sequential, .budget(.thorough))
    }

    @Test("Duplicate offers preserve statistics with either hash path", arguments: [false, true])
    func duplicateOffers(precomputed: Bool) throws {
        let spec = CorpusLifecycleSpec()
        try spec.offer(request: CorpusOffer(
            marker: 1,
            length: 2,
            edgeMask: 2,
            hitCount: 1,
            isMutable: true,
            isBoundaryDerived: false,
            hasPrecomputedHash: precomputed
        ))
        try spec.repeatAdmitted(index: 0, edgeMask: 128, precomputed: precomputed == false)
        #expect(spec.stateMatches())
        #expect(spec.corpus.entries.count == 1)
        #expect(spec.corpus.incidenceSampleCount == 1)
    }

    @Test("Non-novel and empty offers count as incidence rows until reset")
    func rejectedOffersAndReset() throws {
        let spec = CorpusLifecycleSpec()
        for request in [
            CorpusOffer(
                marker: 0,
                length: 1,
                edgeMask: 0,
                hitCount: 1,
                isMutable: true,
                isBoundaryDerived: false,
                hasPrecomputedHash: false
            ),
            CorpusOffer(
                marker: 1,
                length: 2,
                edgeMask: 6,
                hitCount: 1,
                isMutable: true,
                isBoundaryDerived: false,
                hasPrecomputedHash: false
            ),
            CorpusOffer(
                marker: 2,
                length: 3,
                edgeMask: 2,
                hitCount: 1,
                isMutable: true,
                isBoundaryDerived: false,
                hasPrecomputedHash: false
            ),
        ] {
            try spec.offer(request: request)
            #expect(spec.stateMatches())
        }
        #expect(spec.corpus.entries.count == 1)
        #expect(spec.corpus.coveredEdgeCount == 2)
        #expect(spec.corpus.incidenceSampleCount == 3)
        #expect(spec.corpus.incidenceTotal == 3)
        spec.resetIncidence()
        #expect(spec.stateMatches())
        #expect(spec.corpus.incidenceSampleCount == 0)
        #expect(spec.corpus.incidenceTotal == 0)
    }

    @Test("Quarantining a parent removes it from every subsequent draw")
    func quarantineSelection() throws {
        let spec = CorpusLifecycleSpec()
        for index in 0 ..< 4 {
            try spec.offer(request: CorpusOffer(
                marker: index,
                length: 1,
                edgeMask: 1 << index,
                hitCount: 1,
                isMutable: true,
                isBoundaryDerived: false,
                hasPrecomputedHash: false
            ))
        }
        #expect(spec.corpus.parentIndices.count == 4)
        spec.quarantine(marker: 1, length: 1)
        #expect(spec.stateMatches())
        #expect(spec.corpus.parentIndices.count == 3)
        for index in 0 ..< 20 {
            try spec.selectParent(random: Double(index) / 20)
        }
    }
}

// MARK: - Spec

/// Models admission and archive membership with sets and per-edge winners, independent of the corpus's masks, champion counters, and cached score tables.
///
/// Eight edges and sixteen markers deliberately encourage collisions; lengths are bounded to keep histories cheap. Tier inputs straddle 0.5. Numerical scoring, lineage, restoration, mutation-target caching, and full-tree upgrades retain their dedicated core tests.
@StateMachine
private final class CorpusLifecycleSpec {
    static let offers = #gen(
        .int(in: 0 ... 15),
        .int(in: 1 ... 8),
        .int(in: 0 ... 255),
        .uint8(in: 1 ... 255),
        .bool(),
        .bool(),
        .bool()
    ) { marker, length, edgeMask, hitCount, mutable, boundary, precomputed in
        CorpusOffer(
            marker: marker,
            length: length,
            edgeMask: edgeMask,
            hitCount: hitCount,
            isMutable: mutable,
            isBoundaryDerived: boundary,
            hasPrecomputedHash: precomputed
        )
    }

    @SystemUnderTest var corpus = FuzzCorpus(edgeCount: 8)
    private var admitted: [CorpusOffer] = []
    private var novelty: Set<EdgeBucket> = []
    private var covered: Set<Int> = []
    private var quarantined: Set<CorpusIdentity> = []
    private var champions: [Int: Int] = [:]
    private var incidenceRows = 0
    private var incidenceTotal = 0

    @Command(weight: 5, offers)
    func offer(request: CorpusOffer) throws {
        let signature = Set(request.edges.map { EdgeBucket(edge: $0, bucket: bucket(for: request.hitCount)) })
        let novel = signature.subtracting(novelty).isEmpty == false
        try check(corpus.wouldAdmit(hits: request.hits) == novel, "novelty preflight disagrees")
        let actual = corpus.offer(
            sequence: request.identity.sequence,
            tree: .just,
            hits: request.hits,
            convergence: request.isMutable ? 0.5 : 0.49,
            generation: 0,
            phase: .sampling,
            isBoundaryDerived: request.isBoundaryDerived,
            precomputedHash: request.hasPrecomputedHash ? ZobristHash.hash(of: request.identity.sequence) : nil
        )
        if admitted.contains(where: { $0.identity == request.identity }) {
            try check(actual == .rejectedDuplicate, "duplicate was admitted or misclassified")
            return
        }
        incidenceRows += 1
        incidenceTotal += request.edges.count
        guard novel || request.isBoundaryDerived else {
            try check(actual == .rejectedNotNovel, "non-novel candidate was admitted")
            return
        }
        let index = admitted.count
        admitted.append(request)
        novelty.formUnion(signature)
        covered.formUnion(request.edges)
        try check(
            actual == .admitted(index: index, tier: request.isMutable ? .mutable : .discovery),
            "wrong admission or tier"
        )
        if request.isMutable, quarantined.contains(request.identity) == false {
            for edge in request.edges {
                let contenders = [champions[edge], index].compactMap { $0 }
                champions[edge] = contenders.min {
                    let first = admitted[$0].identity
                    let second = admitted[$1].identity
                    return (first.length, first.marker) < (second.length, second.marker)
                }
            }
        }
    }

    @Command(weight: 2, .int(in: 0 ... 15), .int(in: 0 ... 255), .bool())
    func repeatAdmitted(index: Int, edgeMask: Int, precomputed: Bool) throws {
        guard admitted.isEmpty == false else {
            throw skip()
        }
        var request = admitted[index % admitted.count]
        request.edgeMask = edgeMask
        request.hasPrecomputedHash = precomputed
        try offer(request: request)
    }

    @Command(.int(in: 0 ... 15), .int(in: 1 ... 8))
    func quarantine(marker: Int, length: Int) {
        let identity = CorpusIdentity(marker: marker, length: length)
        quarantined.insert(identity)
        champions = champions.filter { admitted[$0.value].identity != identity }
        corpus.quarantine(sequenceHash: ZobristHash.hash(of: identity.sequence))
    }

    @Command(.int(in: 0 ... 15))
    func quarantineAdmitted(index: Int) throws {
        guard admitted.isEmpty == false else {
            throw skip()
        }
        let identity = admitted[index % admitted.count].identity
        quarantine(marker: identity.marker, length: identity.length)
    }

    @Command
    func resetNovelty() {
        novelty.removeAll()
        corpus.resetNoveltyBaseline()
    }

    @Command
    func resetIncidence() {
        incidenceRows = 0
        incidenceTotal = 0
        corpus.resetIncidenceStatistics()
    }

    @Command(.double(in: 0 ... Double(1).nextDown))
    func selectParent(random: Double) throws {
        let selected = corpus.pickParent(random: random)
        if champions.isEmpty {
            try check(selected == nil, "empty archive returned a parent")
        } else {
            guard let selected else {
                try check(false, "nonempty archive returned no parent")
                return
            }
            try check(Set(champions.values).contains(selected.index), "selected a non-champion")
            try check(
                selected.entry.sequence == admitted[selected.index].identity.sequence,
                "returned the wrong parent entry"
            )
        }
    }

    @Invariant
    func stateMatches() -> Bool {
        corpus.entries.map(\.sequence) == admitted.map { $0.identity.sequence }
            && Set(corpus.parentIndices) == Set(champions.values)
            && corpus.parentIndices.count == Set(champions.values).count
            && corpus.parentIndices.count <= covered.count
            && corpus.coveredEdgeCount == covered.count
            && corpus.incidenceSampleCount == incidenceRows
            && corpus.incidenceTotal == incidenceTotal
    }

    func failureDescription() -> String? {
        "admitted=\(admitted), champions=\(champions), parents=\(corpus.parentIndices), incidence=\(incidenceRows)/\(incidenceTotal)"
    }
}

// MARK: - Model Inputs

private struct CorpusOffer: Sendable {
    let marker: Int
    let length: Int
    var edgeMask: Int
    let hitCount: UInt8
    let isMutable: Bool
    let isBoundaryDerived: Bool
    var hasPrecomputedHash: Bool

    var identity: CorpusIdentity {
        CorpusIdentity(marker: marker, length: length)
    }

    var edges: [Int] {
        (0 ..< 8).filter { edgeMask & (1 << $0) != 0 }
    }

    var hits: [(edge: Int, hitCount: UInt8)] {
        edges.map { ($0, hitCount) }
    }
}

private struct CorpusIdentity: Hashable {
    let marker: Int
    let length: Int

    var sequence: ChoiceSequence {
        var result: ChoiceSequence = [.value(.init(choice: ChoiceValue(UInt64(marker), tag: .uint64), validRange: nil))]
        result.append(contentsOf: ChoiceSequence(repeating: .just, count: length - 1))
        return result
    }
}

private struct EdgeBucket: Hashable {
    let edge: Int
    let bucket: Int
}

private func bucket(for count: UInt8) -> Int {
    switch count {
        case 1: 1
        case 2: 2
        case 3: 3
        case 4 ... 7: 4
        case 8 ... 15: 5
        case 16 ... 31: 6
        case 32 ... 127: 7
        default: 8
    }
}
