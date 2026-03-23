import Testing
@testable import ExhaustCore

// MARK: - Convergence Cache Unit Tests

@Suite("ConvergenceCache")
struct ConvergenceCacheUnitTests {
    @Test("Record and retrieve converged origins")
    func recordAndRetrieve() {
        var cache = ConvergenceCache()
        #expect(cache.isEmpty)
        #expect(cache.convergedOrigin(at: 0) == nil)

        cache.record(index: 5, convergedOrigin: makeOrigin(bound: 42, configuration: .binarySearchRangeMinimum))
        #expect(cache.isEmpty == false)

        let entry = cache.convergedOrigin(at: 5)
        #expect(entry?.bound == 42)
        #expect(entry?.configuration == .binarySearchRangeMinimum)
        #expect(entry?.signal == .monotoneConvergence)
        #expect(cache.convergedOrigin(at: 0) == nil)
    }

    @Test("invalidateAll clears all entries")
    func invalidateAll() {
        var cache = ConvergenceCache()
        cache.record(index: 0, convergedOrigin: makeOrigin(bound: 10, configuration: .binarySearchRangeMinimum))
        cache.record(index: 1, convergedOrigin: makeOrigin(bound: 20, configuration: .binarySearchSemanticSimplest))
        #expect(cache.isEmpty == false)

        cache.invalidateAll()
        #expect(cache.isEmpty)
        #expect(cache.convergedOrigin(at: 0) == nil)
        #expect(cache.convergedOrigin(at: 1) == nil)
    }

    @Test("allEntries returns nil when empty")
    func allEntriesEmpty() {
        let cache = ConvergenceCache()
        #expect(cache.allEntries == nil)
    }

    @Test("allEntries returns populated dictionary")
    func allEntriesPopulated() {
        var cache = ConvergenceCache()
        cache.record(index: 3, convergedOrigin: makeOrigin(bound: 100, configuration: .binarySearchRangeMinimum))
        let entries = cache.allEntries
        #expect(entries?.count == 1)
        #expect(entries?[3]?.bound == 100)
    }

    @Test("Later records overwrite earlier ones at the same index")
    func overwrite() {
        var cache = ConvergenceCache()
        cache.record(index: 0, convergedOrigin: makeOrigin(bound: 10, configuration: .binarySearchRangeMinimum))
        cache.record(index: 0, convergedOrigin: makeOrigin(bound: 20, configuration: .binarySearchSemanticSimplest))
        let entry = cache.convergedOrigin(at: 0)
        #expect(entry?.bound == 20)
        #expect(entry?.configuration == .binarySearchSemanticSimplest)
    }
}

// MARK: - Converged Origin Probe Savings

@Suite("Converged Origin Probe Savings")
struct ConvergedOriginProbeSavingsTests {
    @Test("Converged-origin search produces zero probes when bound equals current value")
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
            convergedOrigins: [0: makeOrigin(bound: value, configuration: .binarySearchSemanticSimplest)]
        )

        #expect(coldCount >= 15)
        #expect(warmCount == 0)
    }

    @Test("Eight coordinates each skip binary search with converged origins")
    func eightCoordinateSkip() {
        var values: [UInt64] = []
        var convergedOrigins: [Int: ConvergedOrigin] = [:]
        for i in 0 ..< 8 {
            let value = UInt64(500_000 + i * 100_000)
            values.append(value)
            convergedOrigins[i] = makeOrigin(bound: value, configuration: .binarySearchSemanticSimplest)
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
            convergedOrigins: convergedOrigins
        )

        #expect(coldCount >= 100)
        #expect(warmCount == 0)
    }

    @Test("Convergence records contain convergence bounds for cache harvesting")
    func convergenceRecordsPopulated() {
        let seq = makeUnsignedSequence([1_000_000])
        let spans = extractValueSpans(from: seq)

        var encoder = BinarySearchToSemanticSimplestEncoder()
        encoder.start(sequence: seq, tree: .just(""), positionRange: 0 ... max(0, seq.count - 1), context: ReductionContext())
        while encoder.nextProbe(lastAccepted: false) != nil {}

        let records = encoder.convergenceRecords
        #expect(records.count == 1)
        #expect(records[0]?.bound == 1_000_000)
        #expect(records[0]?.configuration == .binarySearchSemanticSimplest)
    }

    @Test("Range minimum encoder also skips search with matching converged origin")
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
            convergedOrigins: [0: makeOrigin(bound: value, configuration: .binarySearchRangeMinimum)]
        )

        #expect(coldCount >= 15)
        #expect(warmCount == 0)
    }
}

// MARK: - Validation Probe

@Suite("Validation Probe")
struct ValidationProbeTests {
    @Test("Validation probe at floor - 1 is emitted after converged-origin convergence")
    func emitsValidationProbe() {
        // Value at 10000, converged origin at 5000. After binary search over [5000, 10000]
        // converges with all rejections, a validation probe at 4999 is emitted.
        let seq = makeUnsignedSequence([10000])
        let spans = extractValueSpans(from: seq)
        let convergedOrigins: [Int: ConvergedOrigin] = [
            0: makeOrigin(bound: 5000, configuration: .binarySearchRangeMinimum),
        ]

        var encoder = BinarySearchToRangeMinimumEncoder()
        encoder.start(sequence: seq, tree: .just(""), positionRange: 0 ... max(0, seq.count - 1), context: ReductionContext(convergedOrigins: convergedOrigins))

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
        let convergedOrigins: [Int: ConvergedOrigin] = [
            0: makeOrigin(bound: 5000, configuration: .binarySearchRangeMinimum),
        ]

        var encoder = BinarySearchToRangeMinimumEncoder()
        encoder.start(sequence: seq, tree: .just(""), positionRange: 0 ... max(0, seq.count - 1), context: ReductionContext(convergedOrigins: convergedOrigins))

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

// MARK: - Linear Scan Encoder

@Suite("LinearScanEncoder")
struct LinearScanEncoderTests {
    @Test("Upward scan produces probes in ascending order")
    func upwardScanOrder() {
        let seq = makeUnsignedSequence([100])
        var encoder = LinearScanEncoder(
            targetPosition: 0,
            scanRange: 0 ... 4,
            scanDirection: .upward
        )
        encoder.start(
            sequence: seq, tree: .just(""),
            positionRange: 0 ... 0,
            context: ReductionContext()
        )

        var probeValues: [UInt64] = []
        while let probe = encoder.nextProbe(lastAccepted: false) {
            probeValues.append(probe[0].value?.choice.bitPattern64 ?? 0)
        }
        #expect(probeValues == [0, 1, 2, 3, 4])
    }

    @Test("Upward scan stops early on acceptance")
    func upwardScanEarlyStop() {
        let seq = makeUnsignedSequence([100])
        var encoder = LinearScanEncoder(
            targetPosition: 0,
            scanRange: 0 ... 9,
            scanDirection: .upward
        )
        encoder.start(
            sequence: seq, tree: .just(""),
            positionRange: 0 ... 0,
            context: ReductionContext()
        )

        // Reject 0, reject 1, accept 2 → stop.
        var probeCount = 0
        var lastAccepted = false
        while let _ = encoder.nextProbe(lastAccepted: lastAccepted) {
            probeCount += 1
            lastAccepted = (probeCount == 3)
        }
        #expect(probeCount == 3)
    }

    @Test("Convergence record reports scanComplete with foundLowerFloor")
    func convergenceRecordOnAcceptance() {
        let seq = makeUnsignedSequence([100])
        var encoder = LinearScanEncoder(
            targetPosition: 0,
            scanRange: 0 ... 4,
            scanDirection: .upward
        )
        encoder.start(
            sequence: seq, tree: .just(""),
            positionRange: 0 ... 0,
            context: ReductionContext()
        )

        // Accept the first probe (value 0).
        _ = encoder.nextProbe(lastAccepted: false)
        _ = encoder.nextProbe(lastAccepted: true)

        let records = encoder.convergenceRecords
        #expect(records.count == 1)
        #expect(records[0]?.signal == .scanComplete(foundLowerFloor: true))
        #expect(records[0]?.bound == 0)
        #expect(records[0]?.configuration == .linearScan)
    }

    @Test("Convergence record reports scanComplete without lower floor when all rejected")
    func convergenceRecordAllRejected() {
        let seq = makeUnsignedSequence([100])
        var encoder = LinearScanEncoder(
            targetPosition: 0,
            scanRange: 0 ... 2,
            scanDirection: .upward
        )
        encoder.start(
            sequence: seq, tree: .just(""),
            positionRange: 0 ... 0,
            context: ReductionContext()
        )

        while encoder.nextProbe(lastAccepted: false) != nil {}

        let records = encoder.convergenceRecords
        #expect(records.count == 1)
        #expect(records[0]?.signal == .scanComplete(foundLowerFloor: false))
    }

    @Test("Estimated cost equals scan range size")
    func estimatedCost() {
        let seq = makeUnsignedSequence([100])
        let encoder = LinearScanEncoder(
            targetPosition: 0,
            scanRange: 5 ... 14,
            scanDirection: .upward
        )
        let cost = encoder.estimatedCost(
            sequence: seq, tree: .just(""),
            positionRange: 0 ... 0,
            context: ReductionContext()
        )
        #expect(cost == 10)
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
    _ encoder: some ComposableEncoder,
    sequence: ChoiceSequence,
    spans: [ChoiceSpan],
    convergedOrigins: [Int: ConvergedOrigin]? = nil
) -> Int {
    var encoder = encoder
    let positionRange = spans.isEmpty
        ? 0 ... 0
        : spans.map(\.range.lowerBound).min()! ... spans.map(\.range.upperBound).max()!
    encoder.start(
        sequence: sequence,
        tree: .just(""),
        positionRange: positionRange,
        context: ReductionContext(convergedOrigins: convergedOrigins)
    )
    var count = 0
    while encoder.nextProbe(lastAccepted: false) != nil {
        count += 1
    }
    return count
}

private func makeOrigin(
    bound: UInt64,
    configuration: EncoderConfiguration,
    signal: ConvergenceSignal = .monotoneConvergence,
    cycle: Int = 0
) -> ConvergedOrigin {
    ConvergedOrigin(
        bound: bound,
        signal: signal,
        configuration: configuration,
        cycle: cycle
    )
}
