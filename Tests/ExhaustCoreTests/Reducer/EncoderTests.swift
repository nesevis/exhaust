import Testing
@testable import ExhaustCore

// MARK: - Test Helpers

/// Builds a simple choice sequence from raw unsigned values.
private func makeSequence(_ values: [UInt64]) -> ChoiceSequence {
    var seq = ChoiceSequence()
    for v in values {
        seq.append(.value(.init(choice: .unsigned(v, .uint64), validRange: 0 ... UInt64.max, isRangeExplicit: false)))
    }
    return seq
}

/// Extracts all value spans from a sequence.
private func allValueSpans(from seq: ChoiceSequence) -> [ChoiceSpan] {
    var spans: [ChoiceSpan] = []
    for (idx, entry) in seq.enumerated() {
        if entry.value != nil {
            spans.append(ChoiceSpan(kind: .value(.init(choice: .unsigned(0, .uint64), validRange: nil)), range: idx ... idx, depth: 0))
        }
    }
    return spans
}

// MARK: - ZeroValueEncoder

@Suite("ZeroValueEncoder")
struct ZeroValueEncoderTests {
    @Test("Produces one candidate per non-zero target")
    func candidatesPerTarget() {
        let seq = makeSequence([5, 0, 3])
        let spans = allValueSpans(from: seq)
        let encoder = ZeroValueEncoder()
        let candidates = Array(encoder.encode(sequence: seq, targets: .spans(spans)))
        // Value 0 is already at semantic simplest — only 2 candidates.
        #expect(candidates.count == 2)
    }

    @Test("Each candidate sets one value to zero")
    func candidateSetsOneToZero() {
        let seq = makeSequence([5, 7])
        let spans = allValueSpans(from: seq)
        let encoder = ZeroValueEncoder()
        let candidates = Array(encoder.encode(sequence: seq, targets: .spans(spans)))
        #expect(candidates.count == 2)
        // First candidate zeros index 0.
        #expect(candidates[0][0].value?.choice == .unsigned(0, .uint64))
        #expect(candidates[0][1].value?.choice == .unsigned(7, .uint64))
        // Second candidate zeros index 1.
        #expect(candidates[1][0].value?.choice == .unsigned(5, .uint64))
        #expect(candidates[1][1].value?.choice == .unsigned(0, .uint64))
    }

    @Test("Every candidate is shortlex ≤ the input")
    func shortlexInvariant() {
        let seq = makeSequence([10, 20, 30])
        let spans = allValueSpans(from: seq)
        let encoder = ZeroValueEncoder()
        for candidate in encoder.encode(sequence: seq, targets: .spans(spans)) {
            #expect(candidate.shortLexPrecedes(seq))
        }
    }

    @Test("Empty targets produce no candidates")
    func emptyTargets() {
        let seq = makeSequence([5])
        let encoder = ZeroValueEncoder()
        let candidates = Array(encoder.encode(sequence: seq, targets: .spans([])))
        #expect(candidates.isEmpty)
    }

    @Test("Wrong target type produces no candidates")
    func wrongTargetType() {
        let seq = makeSequence([5])
        let encoder = ZeroValueEncoder()
        let candidates = Array(encoder.encode(sequence: seq, targets: .wholeSequence))
        #expect(candidates.isEmpty)
    }
}

// MARK: - FindIntegerStepper

@Suite("FindIntegerStepper")
struct FindIntegerStepperTests {
    @Test("Immediate rejection converges to 0")
    func immediateRejection() {
        var stepper = FindIntegerStepper()
        let first = stepper.start()
        #expect(first == 1)
        let next = stepper.advance(lastAccepted: false)
        #expect(next == nil)
        #expect(stepper.bestAccepted == 0)
    }

    @Test("Linear scan finds small values")
    func linearScan() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // probe 1
        _ = stepper.advance(lastAccepted: true) // probe 2
        let three = stepper.advance(lastAccepted: true) // probe 3
        #expect(three == 3)
        let result = stepper.advance(lastAccepted: false) // rejected at 3
        #expect(result == nil)
        #expect(stepper.bestAccepted == 2)
    }

    @Test("Transitions to exponential phase after 4")
    func exponentialPhase() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // 1
        _ = stepper.advance(lastAccepted: true) // 2
        _ = stepper.advance(lastAccepted: true) // 3
        _ = stepper.advance(lastAccepted: true) // 4
        let eight = stepper.advance(lastAccepted: true) // → exponential, probe 8
        #expect(eight == 8)
    }

    @Test("Binary search converges between bounds")
    func binarySearchConverges() {
        var stepper = FindIntegerStepper()
        _ = stepper.start() // 1
        _ = stepper.advance(lastAccepted: true) // 2
        _ = stepper.advance(lastAccepted: true) // 3
        _ = stepper.advance(lastAccepted: true) // 4
        _ = stepper.advance(lastAccepted: true) // 8
        _ = stepper.advance(lastAccepted: false) // rejected at 8 → binary between 4 and 8
        // Stepper should binary search and eventually converge.
        var probes = 0
        var lastResult: Int? = 1
        while lastResult != nil {
            lastResult = stepper.advance(lastAccepted: true)
            probes += 1
            if probes > 20 { break }
        }
        // bestAccepted should be near 8 (all accepted during binary search).
        #expect(stepper.bestAccepted >= 4)
        #expect(stepper.bestAccepted < 8)
    }
}

// MARK: - BinarySearchStepper

@Suite("BinarySearchStepper")
struct BinarySearchStepperTests {
    @Test("Converged range returns nil immediately")
    func convergedRange() {
        var stepper = BinarySearchStepper(lo: 5, hi: 5)
        let first = stepper.start()
        #expect(first == nil)
    }

    @Test("Adjacent range converges in one probe")
    func adjacentRange() {
        var stepper = BinarySearchStepper(lo: 0, hi: 1)
        let first = stepper.start()
        #expect(first == 0)
        let next = stepper.advance(lastAccepted: true)
        #expect(next == nil)
        #expect(stepper.bestAccepted == 0)
    }

    @Test("Binary search narrows toward lo on acceptance")
    func narrowsTowardLo() {
        var stepper = BinarySearchStepper(lo: 0, hi: 100)
        let first = stepper.start() // 50
        #expect(first == 50)
        let second = stepper.advance(lastAccepted: true) // accepted 50 → hi=50, probe 25
        #expect(second == 25)
        let third = stepper.advance(lastAccepted: true) // accepted 25 → hi=25, probe 12
        #expect(third == 12)
    }

    @Test("Binary search narrows toward hi on rejection")
    func narrowsTowardHi() {
        var stepper = BinarySearchStepper(lo: 0, hi: 100)
        _ = stepper.start() // 50
        let second = stepper.advance(lastAccepted: false) // rejected 50 → lo=51, probe 75
        #expect(second == 75)
    }

    @Test("Converges to exact value")
    func convergesToExact() {
        // Target: largest accepted is 7 (lo=0, hi=10, answer=7)
        var stepper = BinarySearchStepper(lo: 0, hi: 10)
        _ = stepper.start() // 5
        _ = stepper.advance(lastAccepted: true) // hi=5, probe 2
        _ = stepper.advance(lastAccepted: true) // hi=2, probe 1
        _ = stepper.advance(lastAccepted: true) // hi=1, probe 0
        let result = stepper.advance(lastAccepted: true) // hi=0, converged
        #expect(result == nil)
        #expect(stepper.bestAccepted == 0)
    }
}

// MARK: - BinarySearchToZeroEncoder

@Suite("BinarySearchToZeroEncoder")
struct BinarySearchToZeroEncoderTests {
    @Test("Converges a single target to zero with all-accepted feedback")
    func singleTargetAllAccepted() {
        let seq = makeSequence([8])
        let spans = allValueSpans(from: seq)
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: seq, targets: TargetSet.spans(spans))

        var probes: [ChoiceSequence] = []
        var accepted = false
        while let probe = encoder.nextProbe(lastAccepted: accepted) {
            probes.append(probe)
            accepted = true // Accept everything — converge to 0.
        }
        #expect(probes.isEmpty == false)
        // Last probe should have value 0 or close to it.
        let lastValue = probes.last?[0].value?.choice
        #expect(lastValue == .unsigned(0, .uint64))
    }

    @Test("Skips targets already at zero")
    func skipsAlreadyZero() {
        let seq = makeSequence([0, 5])
        let spans = allValueSpans(from: seq)
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: seq, targets: TargetSet.spans(spans))

        // Only index 1 should be probed.
        var probeCount = 0
        while let probe = encoder.nextProbe(lastAccepted: true) {
            // Index 0 should remain 0 in every probe.
            #expect(probe[0].value?.choice == .unsigned(0, .uint64))
            probeCount += 1
            if probeCount > 20 { break }
        }
        #expect(probeCount > 0)
    }

    @Test("Empty targets produce no probes")
    func emptyTargets() {
        var encoder = BinarySearchToZeroEncoder()
        encoder.start(sequence: makeSequence([5]), targets: TargetSet.spans([]))
        let probe = encoder.nextProbe(lastAccepted: false)
        #expect(probe == nil)
    }
}
