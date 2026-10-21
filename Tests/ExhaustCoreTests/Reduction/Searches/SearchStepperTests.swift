import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("BinarySearchStepper")
struct BinarySearchStepperTests {
    @Test("findLargest biases midpoint above findSmallest for odd ranges")
    func findLargestRoundsUpOdd() {
        var largestStepper = BinarySearchStepper(lo: 0, hi: 99, direction: .findLargest)
        var smallestStepper = BinarySearchStepper(lo: 0, hi: 99, direction: .findSmallest)

        #expect(largestStepper.start() == 50, "findLargest rounds up: 0 + 49 + 1")
        #expect(smallestStepper.start() == 49, "findSmallest rounds down: 0 + 99/2")
    }

    // MARK: - Edge Cases

    @Test("Equal lo and hi returns nil immediately")
    func equalBoundsReturnsNil() {
        var stepper = BinarySearchStepper(lo: 42, hi: 42, direction: .findSmallest)
        #expect(stepper.start() == nil)
    }

    @Test("Adjacent lo and hi returns single probe")
    func adjacentBoundsReturnsOneProbe() {
        var stepper = BinarySearchStepper(lo: 5, hi: 6, direction: .findSmallest)
        let first = stepper.start()
        #expect(first == 5)
        let second = stepper.advance(lastAccepted: false)
        #expect(second == nil)
    }

    @Test("Terminates in O(log n) probes")
    func logNTermination() {
        var stepper = BinarySearchStepper(lo: 0, hi: 1_000_000, direction: .findSmallest)
        _ = stepper.start()
        var probeCount = 1
        while stepper.advance(lastAccepted: false) != nil {
            probeCount += 1
        }
        #expect(probeCount <= 20)
    }

    @Test("findLargest handles UInt64.max overflow gracefully")
    func findLargestMaxOverflow() {
        var stepper = BinarySearchStepper(lo: UInt64.max - 1, hi: UInt64.max, direction: .findLargest)
        let first = stepper.start()
        #expect(first != nil)
        if first != nil {
            let next = stepper.advance(lastAccepted: true)
            #expect(next == nil)
        }
    }
}

@Suite("InterpolationSearchStepper")
struct InterpolationSearchStepperTests {
    // MARK: - findSmallest

    @Test("Initial probe biases toward lo in findSmallest mode")
    func initialProbeBiasLo() {
        var stepper = InterpolationSearchStepper(lo: 0, hi: 100_000, direction: .findSmallest)
        let first = stepper.start()
        #expect(first != nil)
        if let probe = first {
            #expect(probe < 50000, "Interpolation should probe closer to lo than midpoint")
        }
    }

    @Test("Initial probe biases toward hi in findLargest mode")
    func initialProbeBiasHi() {
        var stepper = InterpolationSearchStepper(lo: 0, hi: 100_000, direction: .findLargest)
        let first = stepper.start()
        #expect(first != nil)
        if let probe = first {
            #expect(probe > 50000, "Interpolation should probe closer to hi than midpoint")
        }
    }

    // MARK: - Divisor Halving on Rejection

    @Test("Divisor halves on rejection, widening the probe step")
    func divisorHalvesOnRejection() {
        var stepper = InterpolationSearchStepper(lo: 0, hi: 100_000, direction: .findSmallest)
        guard let first = stepper.start() else {
            Issue.record("Expected non-nil first probe")
            return
        }
        let step1 = first

        guard let second = stepper.advance(lastAccepted: false) else {
            Issue.record("Expected second probe after rejection")
            return
        }
        let step2 = second - first

        #expect(step2 > step1, "Rejection should halve the divisor, producing a wider step")
    }

    @Test("Divisor resets on acceptance, biasing the next probe toward lo in the narrowed range")
    func divisorResetsOnAcceptance() {
        var stepper = InterpolationSearchStepper(lo: 0, hi: 100_000, direction: .findSmallest)
        guard let probe1 = stepper.start() else {
            Issue.record("Expected first probe")
            return
        }
        guard let probe2 = stepper.advance(lastAccepted: false) else {
            Issue.record("Expected second probe after rejection")
            return
        }
        guard let probe3 = stepper.advance(lastAccepted: false) else {
            Issue.record("Expected third probe after second rejection")
            return
        }
        _ = probe1

        guard let probe4 = stepper.advance(lastAccepted: true) else {
            Issue.record("Expected probe after acceptance")
            return
        }

        let narrowedMidpoint = (probe2 + 1) + (probe3 - probe2 - 1) / 2
        #expect(probe4 < narrowedMidpoint, "Reset divisor should bias probe toward lo, not the midpoint")
    }

    // MARK: - Binary Threshold Fallback

    @Test("Falls back to binary search below threshold")
    func binaryThresholdFallback() {
        let threshold = InterpolationSearchStepper.binaryThreshold
        var stepper = InterpolationSearchStepper(lo: 0, hi: threshold - 1, direction: .findSmallest)
        let first = stepper.start()
        #expect(first != nil)
        if let probe = first {
            let expectedMidpoint = (threshold - 1) / 2
            #expect(probe == expectedMidpoint, "Below threshold, should use binary search midpoint")
        }
    }

    // MARK: - Edge Cases

    @Test("Equal lo and hi returns nil immediately")
    func equalBoundsReturnsNil() {
        var stepper = InterpolationSearchStepper(lo: 42, hi: 42, direction: .findSmallest)
        #expect(stepper.start() == nil)
    }

    @Test("Terminates in bounded number of probes")
    func boundedTermination() {
        var stepper = InterpolationSearchStepper(lo: 0, hi: 1_000_000, direction: .findSmallest)
        _ = stepper.start()
        var probeCount = 1
        while stepper.advance(lastAccepted: false) != nil {
            probeCount += 1
        }
        #expect(probeCount <= 30)
    }
}

@Suite("Search stepper boundary contracts")
struct SearchStepperContractTests {
    @Test("Both steppers find the boundary of a monotone predicate", arguments: [SearchDirection.findSmallest, .findLargest])
    func monotoneBoundary(direction: SearchDirection) throws {
        // Bounded intervals make a linear scan an independent oracle. The existing UInt64.max
        // vector separately covers arithmetic overflow beyond this generated resource bound.
        let inputs = Gen.zip(Gen.choose(in: 0 ... 1000), Gen.choose(in: 0 ... 10000), Gen.choose(in: -1 ... 10001))
        try exhaustCheck(inputs, maxIterations: 300) { lower, width, offset in
            let upper = lower + width
            let threshold = lower + min(offset, width + 1)
            let accepted: (Int) -> Bool = { direction == .findLargest ? $0 <= threshold : $0 >= threshold }
            let permitted = (lower ... upper).filter(accepted)
            let expected = direction == .findLargest ? (permitted.last ?? lower) : (permitted.first ?? upper)
            var binary = BinarySearchStepper(lo: UInt64(lower), hi: UInt64(upper), direction: direction)
            var interpolation = InterpolationSearchStepper(lo: UInt64(lower), hi: UInt64(upper), direction: direction)
            var binaryProbe = binary.start()
            var interpolationProbe = interpolation.start()
            for _ in 0 ..< 64 {
                if let probe = binaryProbe {
                    binaryProbe = binary.advance(lastAccepted: accepted(Int(probe)))
                }
                if let probe = interpolationProbe {
                    interpolationProbe = interpolation.advance(lastAccepted: accepted(Int(probe)))
                }
                if binaryProbe == nil, interpolationProbe == nil {
                    break
                }
            }
            return binaryProbe == nil && interpolationProbe == nil
                && binary.bestAccepted == UInt64(expected)
                && interpolation.bestAccepted == UInt64(expected)
        }
    }
}
