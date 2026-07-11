import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Post-reduction normalization tests")
struct SprawlNormalizerTests {
    /// A mask-gate property: fails while the low two bits are both set. The kind of gate whose
    /// reduction residuals (171, 43, 11) all normalize to the canonical 3.
    private static let maskProperty: @Sendable (Int) -> SprawlVerdict = { value in
        value & 0b11 == 0b11 ? .fail(.returnedFalse) : .pass
    }

    @Test("A stalled mask-gate residual is re-driven to the canonical minimal value")
    func maskGateResidualNormalizes() {
        let cache = SendableBox<[UInt64: ChoiceSequence?]>([:])
        let normalized: SprawlNormalizer.NormalizedForm<Int>? = SprawlNormalizer.normalize(
            reducedSequence: singleValueSequence(171),
            erasedGen: Gen.choose(in: 0 ... 255 as ClosedRange<Int>).erase(),
            symptom: .returnedFalse,
            property: Self.maskProperty,
            cache: cache
        )
        #expect(normalized?.value == 3)
    }

    @Test("A second normalization of the same reduced form is a cache hit with zero probes")
    func cacheHitSkipsProbing() {
        let cache = SendableBox<[UInt64: ChoiceSequence?]>([:])
        let evaluationCount = SendableBox<Int>(0)
        let countingProperty: @Sendable (Int) -> SprawlVerdict = { value in
            evaluationCount.withValue { $0 += 1 }
            return Self.maskProperty(value)
        }
        let erased = Gen.choose(in: 0 ... 255 as ClosedRange<Int>).erase()

        let first: SprawlNormalizer.NormalizedForm<Int>? = SprawlNormalizer.normalize(
            reducedSequence: singleValueSequence(171),
            erasedGen: erased,
            symptom: .returnedFalse,
            property: countingProperty,
            cache: cache
        )
        let probesForFirst = evaluationCount.withValue { $0 }
        #expect(first?.value == 3)
        #expect(probesForFirst > 0)

        let second: SprawlNormalizer.NormalizedForm<Int>? = SprawlNormalizer.normalize(
            reducedSequence: singleValueSequence(171),
            erasedGen: erased,
            symptom: .returnedFalse,
            property: countingProperty,
            cache: cache
        )
        #expect(second?.value == 3)
        #expect(evaluationCount.withValue { $0 } == probesForFirst, "the cached result must not re-probe the property")
    }

    @Test("An already-canonical form normalizes to nothing and caches the negative result")
    func canonicalFormIsANoOp() {
        let cache = SendableBox<[UInt64: ChoiceSequence?]>([:])
        let equalityProperty: @Sendable (Int) -> SprawlVerdict = { value in
            value == 171 ? .fail(.returnedFalse) : .pass
        }
        let erased = Gen.choose(in: 0 ... 255 as ClosedRange<Int>).erase()
        let outcome: SprawlNormalizer.NormalizedForm<Int>? = SprawlNormalizer.normalize(
            reducedSequence: singleValueSequence(171),
            erasedGen: erased,
            symptom: .returnedFalse,
            property: equalityProperty,
            cache: cache
        )
        #expect(outcome == nil)
        // The negative result is cached as an explicit nil entry, not an absence.
        let cachedEntry: ChoiceSequence?? = cache.withValue { $0[ZobristHash.hash(of: singleValueSequence(171))] }
        guard case .some(.none) = cachedEntry else {
            Issue.record("expected an explicit cached nil, got \(String(describing: cachedEntry))")
            return
        }
    }

    @Test("A probe that slips to a different symptom is rejected")
    func symptomSlippageIsRejected() {
        // 171 fails with A; every simpler bit pattern that still fails does so with B. Normalization must keep 171 rather than slip the cluster onto B's fault.
        let slippingProperty: @Sendable (Int) -> SprawlVerdict = { value in
            if value == 171 {
                return .fail(FailureSymptom(kind: "A"))
            }
            return value & 0b11 == 0b11 ? .fail(FailureSymptom(kind: "B")) : .pass
        }
        let cache = SendableBox<[UInt64: ChoiceSequence?]>([:])
        let outcome: SprawlNormalizer.NormalizedForm<Int>? = SprawlNormalizer.normalize(
            reducedSequence: singleValueSequence(171),
            erasedGen: Gen.choose(in: 0 ... 255 as ClosedRange<Int>).erase(),
            symptom: FailureSymptom(kind: "A"),
            property: slippingProperty,
            cache: cache
        )
        #expect(outcome == nil)
    }

    @Test("Unnormalized members are counted on the cluster they normalize into")
    func unnormalizedMemberRecording() {
        let inventory = FaultInventory()
        _ = inventory.recordReduced(
            reducedSequence: singleValueSequence(3),
            reducedKey: "canonical",
            renderDescription: { "3" },
            signature: nil,
            symptom: .returnedFalse,
            phase: .sprawl,
            timestampNanoseconds: 10,
            attemptIndex: 1
        )
        let residual = inventory.recordReduced(
            reducedSequence: singleValueSequence(3),
            reducedKey: "canonical",
            renderDescription: { "3" },
            signature: nil,
            symptom: .returnedFalse,
            phase: .sprawl,
            timestampNanoseconds: 20,
            attemptIndex: 2,
            unnormalizedResidual: true
        )
        #expect(residual.isNewCluster == false)
        let clusters = inventory.snapshot()
        #expect(clusters.count == 1)
        #expect(clusters[0].instanceCount == 2)
        #expect(clusters[0].unnormalizedMemberCount == 1)
    }
}

// MARK: - Helpers

/// A one-entry sequence matching what `Gen.choose(in: 0 ... 255 as ClosedRange<Int>)` flattens to. `Int` choices use offset-binary bit patterns (2⁶³ + value), so unsigned pattern order matches signed value order; the valid range pins the offset bit, which is what keeps the normalizer's bit-clearing from ever leaving the declared domain.
private func singleValueSequence(_ value: UInt64) -> ChoiceSequence {
    let offset = UInt64(1) << 63
    return [
        .value(ChoiceSequenceValue.Value(
            choice: ChoiceValue(offset + value, tag: .int),
            validRange: offset ... offset + 255,
            isRangeExplicit: true
        )),
    ]
}
