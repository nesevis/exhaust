//
//  AdaptiveProbeTests.swift
//  Exhaust
//
//  Created by Chris Kolbu on 12/2/2026.
//

import Testing
@testable import ExhaustCore

// MARK: - findInteger

@Suite("AdaptiveProbe.findInteger")
struct FindIntegerTests {
    @Test("Returns 0 when predicate fails immediately")
    func failsAtOne() {
        let result: Int = AdaptiveProbe.findInteger { _ in false }
        #expect(result == 0)
    }

    @Test("Finds small thresholds within the linear scan range")
    func smallThresholds() {
        for threshold in 1 ... 3 {
            let result: Int = AdaptiveProbe.findInteger { $0 <= threshold }
            #expect(result == threshold)
        }
    }

    @Test("Finds threshold at boundary between linear scan and exponential probe")
    func linearScanBoundary() {
        // low starts at 1, high starts at 5; linear scan covers 1..<4
        let result: Int = AdaptiveProbe.findInteger { $0 <= 4 }
        #expect(result == 4)
    }

    @Test("Finds thresholds requiring exponential probing")
    func exponentialProbe() {
        let result: Int = AdaptiveProbe.findInteger { $0 <= 100 }
        #expect(result == 100)
    }

    @Test("Finds large thresholds", arguments: [1000, 10000, 100_000])
    func largeThresholds(threshold: Int) {
        let result: Int = AdaptiveProbe.findInteger { $0 <= threshold }
        #expect(result == threshold)
    }

    @Test("Works with UInt64")
    func worksWithUInt64() {
        let result: UInt64 = AdaptiveProbe.findInteger { $0 <= 42 }
        #expect(result == 42)
    }

    @Test("Predicate is never called with 0")
    func neverCalledWithZero() {
        let _: Int = AdaptiveProbe.findInteger { k in
            #expect(k > 0, "predicate(0) must not be called")
            return k <= 10
        }
    }

    @Test("Evaluates predicate a logarithmic number of times")
    func logarithmicCost() {
        let threshold = 1000
        var callCount = 0
        let result: Int = AdaptiveProbe.findInteger { k in
            callCount += 1
            return k <= threshold
        }
        #expect(result == threshold)
        // O(log k) — should be well under a linear scan
        #expect(callCount < 50)
    }
}

// MARK: - binarySearchWithGuess

@Suite("AdaptiveProbe.binarySearchWithGuess")
struct BinarySearchWithGuessTests {
    @Test("Finds transition point with no guess (defaults to low)")
    func noGuess() {
        // predicate: true for n <= 50, false for n > 50
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 50 }, low: 0, high: 100,
        )
        #expect(result == 50)
    }

    @Test("Finds transition point with exact guess")
    func exactGuess() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 50 }, low: 0, high: 100, guess: 50,
        )
        #expect(result == 50)
    }

    @Test("Finds transition point when guess is too low")
    func guessLow() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 75 }, low: 0, high: 100, guess: 10,
        )
        #expect(result == 75)
    }

    @Test("Finds transition point when guess is too high")
    func guessHigh() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 25 }, low: 0, high: 100, guess: 80,
        )
        #expect(result == 25)
    }

    @Test("Answer at low bound")
    func answerAtLow() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 0 }, low: 0, high: 100, guess: 50,
        )
        #expect(result == 0)
    }

    @Test("Answer just below high bound")
    func answerJustBelowHigh() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 99 }, low: 0, high: 100, guess: 50,
        )
        #expect(result == 99)
    }

    @Test("Narrow range")
    func narrowRange() {
        let result = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 5 }, low: 5, high: 6, guess: 5,
        )
        #expect(result == 5)
    }

    @Test("Close guess costs fewer evaluations than distant guess")
    func closeGuessIsCheaper() {
        let threshold = 500

        var closeCallCount = 0
        let closeResult = AdaptiveProbe.binarySearchWithGuess(
            { k in closeCallCount += 1; return k <= threshold },
            low: 0, high: 1000, guess: 495,
        )

        var farCallCount = 0
        let farResult = AdaptiveProbe.binarySearchWithGuess(
            { k in farCallCount += 1; return k <= threshold },
            low: 0, high: 1000, guess: 10,
        )

        #expect(closeResult == threshold)
        #expect(farResult == threshold)
        #expect(closeCallCount < farCallCount)
    }

    @Test("Works with UInt64")
    func worksWithUInt64() {
        let result: UInt64 = AdaptiveProbe.binarySearchWithGuess(
            { $0 <= 42 }, low: 0, high: 100, guess: 30,
        )
        #expect(result == 42)
    }
}
