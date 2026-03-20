import Testing
@testable import ExhaustCore

// MARK: - StallCache Unit Tests

@Suite("StallCache")
struct StallCacheTests {
    @Test("Record and retrieve warm starts")
    func recordAndRetrieve() {
        var cache = StallCache()
        #expect(cache.isEmpty)
        #expect(cache.warmStart(at: 0) == nil)

        cache.record(index: 5, warmStart: WarmStart(bound: 42, direction: .downward))
        #expect(cache.isEmpty == false)

        let entry = cache.warmStart(at: 5)
        #expect(entry?.bound == 42)
        #expect(entry?.direction == .downward)
        #expect(cache.warmStart(at: 0) == nil)
    }

    @Test("invalidateAll clears all entries")
    func invalidateAll() {
        var cache = StallCache()
        cache.record(index: 0, warmStart: WarmStart(bound: 10, direction: .downward))
        cache.record(index: 1, warmStart: WarmStart(bound: 20, direction: .upward))
        #expect(cache.isEmpty == false)

        cache.invalidateAll()
        #expect(cache.isEmpty)
        #expect(cache.warmStart(at: 0) == nil)
        #expect(cache.warmStart(at: 1) == nil)
    }

    @Test("allEntries returns nil when empty")
    func allEntriesEmpty() {
        let cache = StallCache()
        #expect(cache.allEntries == nil)
    }

    @Test("allEntries returns populated dictionary")
    func allEntriesPopulated() {
        var cache = StallCache()
        cache.record(index: 3, warmStart: WarmStart(bound: 100, direction: .downward))
        let entries = cache.allEntries
        #expect(entries?.count == 1)
        #expect(entries?[3]?.bound == 100)
    }

    @Test("Later records overwrite earlier ones at the same index")
    func overwrite() {
        var cache = StallCache()
        cache.record(index: 0, warmStart: WarmStart(bound: 10, direction: .downward))
        cache.record(index: 0, warmStart: WarmStart(bound: 20, direction: .upward))
        let entry = cache.warmStart(at: 0)
        #expect(entry?.bound == 20)
        #expect(entry?.direction == .upward)
    }
}

// MARK: - Warm Start Probe Savings

@Suite("Warm Start Probe Savings")
struct WarmStartProbeSavingsTests {
    @Test("Warm-started search produces zero probes when bound equals current value")
    func zeroProbesWhenBoundMatchesCurrent() {
        let value: UInt64 = 1_000_000
        let seq = makeUnsignedSequence([value])
        let spans = extractValueSpans(from: seq)

        // Cold: ~20 probes (log2(1_000_000) ≈ 20).
        let coldCount = countAllRejectedProbes(
            BinarySearchToSemanticSimplestEncoder(),
            sequence: seq, spans: spans
        )
        // Warm: bound == current → lo == hi → 0 probes.
        let warmCount = countAllRejectedProbes(
            BinarySearchToSemanticSimplestEncoder(),
            sequence: seq, spans: spans,
            warmStarts: [0: WarmStart(bound: value, direction: .downward)]
        )

        #expect(coldCount >= 15)
        #expect(warmCount == 0)
    }

    @Test("Eight coordinates each skip binary search with warm starts")
    func eightCoordinateSkip() {
        var values: [UInt64] = []
        var warmStarts: [Int: WarmStart] = [:]
        for i in 0 ..< 8 {
            let value = UInt64(500_000 + i * 100_000)
            values.append(value)
            warmStarts[i] = WarmStart(bound: value, direction: .downward)
        }
        let seq = makeUnsignedSequence(values)
        let spans = extractValueSpans(from: seq)

        let coldCount = countAllRejectedProbes(
            BinarySearchToSemanticSimplestEncoder(),
            sequence: seq, spans: spans
        )
        let warmCount = countAllRejectedProbes(
            BinarySearchToSemanticSimplestEncoder(),
            sequence: seq, spans: spans,
            warmStarts: warmStarts
        )

        #expect(coldCount >= 100)
        #expect(warmCount == 0)
    }

    @Test("Stall records contain convergence bounds for cache harvesting")
    func stallRecordsPopulated() {
        let seq = makeUnsignedSequence([1_000_000])
        let spans = extractValueSpans(from: seq)

        var encoder = BinarySearchToSemanticSimplestEncoder()
        encoder.start(sequence: seq, targets: .spans(spans), warmStarts: nil)
        while encoder.nextProbe(lastAccepted: false) != nil {}

        let records = encoder.stallRecords
        #expect(records.count == 1)
        #expect(records[0]?.bound == 1_000_000)
        #expect(records[0]?.direction == .downward)
    }

    @Test("Range minimum encoder also skips search with matching warm start")
    func rangeMinimumEncoderSkip() {
        let value: UInt64 = 1_000_000
        let seq = makeUnsignedSequence([value])
        let spans = extractValueSpans(from: seq)

        let coldCount = countAllRejectedProbes(
            BinarySearchToRangeMinimumEncoder(),
            sequence: seq, spans: spans
        )
        let warmCount = countAllRejectedProbes(
            BinarySearchToRangeMinimumEncoder(),
            sequence: seq, spans: spans,
            warmStarts: [0: WarmStart(bound: value, direction: .downward)]
        )

        #expect(coldCount >= 15)
        #expect(warmCount == 0)
    }
}

// MARK: - Validation Probe

@Suite("Validation Probe")
struct ValidationProbeTests {
    @Test("Validation probe at floor - 1 is emitted after warm-started convergence")
    func emitsValidationProbe() {
        // Value at 10000, warm start at 5000. After binary search over [5000, 10000]
        // converges with all rejections, a validation probe at 4999 is emitted.
        let seq = makeUnsignedSequence([10000])
        let spans = extractValueSpans(from: seq)
        let warmStarts: [Int: WarmStart] = [
            0: WarmStart(bound: 5000, direction: .downward),
        ]

        var encoder = BinarySearchToRangeMinimumEncoder()
        encoder.start(sequence: seq, targets: .spans(spans), warmStarts: warmStarts)

        var probeValues: [UInt64] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            probeValues.append(probe[0].value?.choice.bitPattern64 ?? 0)
        }

        #expect(probeValues.isEmpty == false)
        // Last probe is the validation probe at floor - 1 = 4999.
        #expect(probeValues.last == 4999)
        // All preceding probes are in the narrowed range [5000, 10000].
        for bitPattern in probeValues.dropLast() {
            #expect(bitPattern >= 5000 && bitPattern <= 10000)
        }
    }

    @Test("Accepted validation probe triggers cold restart with full range")
    func acceptedValidationTriggersColdRestart() {
        let seq = makeUnsignedSequence([10000])
        let spans = extractValueSpans(from: seq)
        let warmStarts: [Int: WarmStart] = [
            0: WarmStart(bound: 5000, direction: .downward),
        ]

        var encoder = BinarySearchToRangeMinimumEncoder()
        encoder.start(sequence: seq, targets: .spans(spans), warmStarts: warmStarts)

        var probeValues: [UInt64] = []
        var lastAccepted = false
        while let probe = encoder.nextProbe(lastAccepted: lastAccepted) {
            let bitPattern = probe[0].value?.choice.bitPattern64 ?? 0
            probeValues.append(bitPattern)
            // Accept only the validation probe at 4999.
            lastAccepted = (bitPattern == 4999)
        }

        // Probes should include values both above 5000 (narrowed search)
        // and below 5000 (cold restart after validation accepted at 4999).
        let aboveFloor = probeValues.filter { $0 >= 5000 }
        let belowFloor = probeValues.filter { $0 < 4999 }
        #expect(aboveFloor.isEmpty == false)
        #expect(belowFloor.isEmpty == false)
    }
}

// MARK: - Helpers

private func makeUnsignedSequence(_ values: [UInt64]) -> ChoiceSequence {
    var seq = ChoiceSequence()
    for value in values {
        seq.append(.value(.init(
            choice: .unsigned(value, .uint64),
            validRange: 0 ... UInt64.max,
            isRangeExplicit: false
        )))
    }
    return seq
}

private func extractValueSpans(from seq: ChoiceSequence) -> [ChoiceSpan] {
    var spans: [ChoiceSpan] = []
    for (index, entry) in seq.enumerated() {
        if entry.value != nil {
            spans.append(ChoiceSpan(
                kind: .value(.init(choice: .unsigned(0, .uint64), validRange: nil)),
                range: index ... index,
                depth: 0
            ))
        }
    }
    return spans
}

private func countAllRejectedProbes(
    _ encoder: some AdaptiveEncoder,
    sequence: ChoiceSequence,
    spans: [ChoiceSpan],
    warmStarts: [Int: WarmStart]? = nil
) -> Int {
    var encoder = encoder
    encoder.start(sequence: sequence, targets: .spans(spans), warmStarts: warmStarts)
    var count = 0
    while encoder.nextProbe(lastAccepted: false) != nil {
        count += 1
    }
    return count
}
