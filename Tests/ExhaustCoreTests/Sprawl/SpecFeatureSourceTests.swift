import Testing
@testable import ExhaustCore

@Suite("SpecFeatureSource bigram features")
struct SpecFeatureSourceTests {
    @Test("Feature edges are appended after the base range with bigram counts")
    func featureEdgesAppendAfterBase() {
        let base = FixedEdgeSource(edgeCount: 10, hits: [(2, 1)])
        let source = SpecFeatureSource(base: base, alphabet: 4, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        // Fingerprints bucket modulo 4: [1, 1, 1] yields the (1, 1) bigram twice.
        source.noteValue([UInt64(1), UInt64(1), UInt64(1)])

        var hits: [Int: UInt8] = [:]
        source.forEachHitEdge { edge, hitCount in
            hits[edge] = hitCount
        }
        #expect(hits[2] == 1, "base edges pass through unchanged")
        let bigramSlot = 10 + (1 * 4 + 1)
        #expect(hits[bigramSlot] == 2, "three identical commands form the same bigram twice")
        #expect(hits.count == 2)
    }

    @Test("Distinct adjacent fingerprints land in distinct bigram slots")
    func distinctBigramsSeparate() {
        let source = SpecFeatureSource(base: FixedEdgeSource(edgeCount: 0, hits: []), alphabet: 4, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        source.noteValue([UInt64(1), UInt64(2), UInt64(1)])

        var hits: [Int: UInt8] = [:]
        source.forEachHitEdge { edge, hitCount in
            hits[edge] = hitCount
        }
        #expect(hits[1 * 4 + 2] == 1)
        #expect(hits[2 * 4 + 1] == 1)
        #expect(hits.count == 2)
    }

    @Test("beginAttempt clears feature counts and forwards to the base")
    func beginAttemptResets() {
        let base = FixedEdgeSource(edgeCount: 4, hits: [])
        let source = SpecFeatureSource(base: base, alphabet: 4, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        source.noteValue([UInt64(0), UInt64(0)])
        source.beginAttempt()

        var hitCount = 0
        source.forEachHitEdge { _, _ in
            hitCount += 1
        }
        #expect(hitCount == 0, "the second attempt starts with no feature counts")
        #expect(base.beginAttemptCalls == 2)
    }

    @Test("Values the extractor cannot map produce no features")
    func unmappableValueProducesNoFeatures() {
        let source = SpecFeatureSource(base: FixedEdgeSource(edgeCount: 0, hits: []), alphabet: 4, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        source.noteValue("not a command sequence")

        var hitCount = 0
        source.forEachHitEdge { _, _ in
            hitCount += 1
        }
        #expect(hitCount == 0)
    }

    @Test("Single-command sequences form no bigram")
    func singleCommandNoBigram() {
        let source = SpecFeatureSource(base: FixedEdgeSource(edgeCount: 0, hits: []), alphabet: 4, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        source.noteValue([UInt64(3)])

        var hitCount = 0
        source.forEachHitEdge { _, _ in
            hitCount += 1
        }
        #expect(hitCount == 0)
    }

    @Test("Bigram counts saturate at 255")
    func countsSaturate() {
        let source = SpecFeatureSource(base: FixedEdgeSource(edgeCount: 0, hits: []), alphabet: 2, fingerprintCommands: fingerprintInts)
        source.beginAttempt()
        source.noteValue(Array(repeating: UInt64(0), count: 400))

        var saturated: UInt8?
        source.forEachHitEdge { _, hitCount in
            saturated = hitCount
        }
        #expect(saturated == 255)
    }

    @Test("The description fingerprint is a pure function of its text")
    func fingerprintIsStable() {
        #expect(SpecFeatureSource.fingerprint(of: "pulse(7)") == SpecFeatureSource.fingerprint(of: "pulse(7)"))
        #expect(SpecFeatureSource.fingerprint(of: "pulse(7)") != SpecFeatureSource.fingerprint(of: "pulse(3)"))
        // The FNV-1a constant for the empty input, pinned so an accidental algorithm change cannot slip through as a mere redistribution: a changed fingerprint reshuffles every persisted expectation of feature admissions.
        #expect(SpecFeatureSource.fingerprint(of: "") == 0xCBF2_9CE4_8422_2325)
    }

    @Test("Streak growth crosses admission buckets at the documented rungs")
    func streakLaddersBuckets() {
        // The mechanism the wrapper exists for: as a same-command streak grows, the bigram count crosses HitCountBucket boundaries at streaks 2, 3, 4, 5, and 9, so each of those prefixes is admission-novel relative to the last.
        var seenMasks: UInt8 = 0
        var admissionStreaks: [Int] = []
        for streak in 2 ... 12 {
            let count = UInt8(streak - 1)
            let mask = HitCountBucket.bucketMask(for: count)
            if seenMasks & mask == 0 {
                admissionStreaks.append(streak)
                seenMasks |= mask
            }
        }
        #expect(admissionStreaks == [2, 3, 4, 5, 9])
    }
}

// MARK: - Helpers

/// Buckets raw `UInt64` test inputs as fingerprints directly, standing in for the adapter's description hashing.
private let fingerprintInts: @Sendable (Any) -> [UInt64]? = { value in
    value as? [UInt64]
}

/// A base source reporting a fixed hit list, counting `beginAttempt` calls.
private final class FixedEdgeSource: CoverageSource, @unchecked Sendable {
    let edgeCount: Int
    private let hits: [(edge: Int, hitCount: UInt8)]
    private(set) var beginAttemptCalls = 0

    init(edgeCount: Int, hits: [(edge: Int, hitCount: UInt8)]) {
        self.edgeCount = edgeCount
        self.hits = hits
    }

    func beginAttempt() {
        beginAttemptCalls += 1
    }

    func forEachHitEdge(_ body: (_ edge: Int, _ hitCount: UInt8) -> Void) {
        for (edge, hitCount) in hits {
            body(edge, hitCount)
        }
    }
}
