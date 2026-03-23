//
//  Difference.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Difference")
struct DifferenceShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/difference.md
     There are two tests in this challenge. Both deal with the absolute difference between two random positive integer parameters.

     Test 1 ("difference must not be zero") only succeeds if
     - the first parameter is less than 10, or:
     - the difference is not zero. The smallest falsified sample is [10, 10]

     Test 2 ("difference must not be small") only succeeds if
     - the first parameter is less than 10, or:
     - the difference is not between 1 and 4. The smallest falsified sample is [10, 6].

     Test 3 ("difference must not be one") only succeeds if
     - the first parameter is less than 10, or:
     -the difference is not exactly 1. The smallest falsified sample is [10, 9].

     Shrinking is a challenge in these examples because it requires keeping up a dependency between two distinct parameters. Additionally, it can be a challenge to find a first failing sample when generation of integers is naively done uniformly across the realm of positive integers.

     Test 3 seems the most difficult one to shrink because shrinking parameters individually will never lead to a smaller and falsifying sample. This is also the hardest to find a falsifying sample in the first place.
     */
    @Test("Difference must not be zero")
    func differenceTest1() {
        let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

        let property: @Sendable ([Int]) -> Bool = { arr in
            arr[0] < 10 || arr[0] != arr[1]
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting([700, 700]),
            .onReport { report = $0 },
            property: property
        )
        if let report { print("[PROFILE] Difference1: \(report.profilingSummary)") }

        #expect(output == [10, 10])
    }

    @Test("Difference must not be small")
    func differenceTest2() {
        let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

        let property: @Sendable ([Int]) -> Bool = { arr in
            let diff = abs(arr[0] - arr[1])
            return arr[0] < 10 || diff < 1 || diff > 4
        }

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting([700, 701]),
            .onReport { report = $0 },
            property: property
        )
        if let report { print("[PROFILE] Difference2: \(report.profilingSummary)") }

        #expect(output == [10, 6])
    }

    @Test("Difference must not be one")
    func differenceTest3() {
        let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .onReport { report = $0 }
        ) { arr in
            let diff = abs(arr[0] - arr[1])
            return arr[0] < 10 || diff != 1
        }
        if let report { print("[PROFILE] Difference3: \(report.profilingSummary)") }
        #expect(output == [10, 9])
    }
}
