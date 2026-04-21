//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import OSLog
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Bound5")
struct Bound5ShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/bound5.md
     Given a 5-tuple of lists of 16-bit integers, we want to test the property that if each list sums to less than 256, then the sum of all the values in the lists is less than 5 * 256. This is false because of overflow. e.g. ([-20000], [-20000], [], [], []) is a counter-example.

     The interesting thing about this example is the interdependence between separate parts of the sample data. A single list in the tuple will never break the invariant, but you need at least two lists together. This prevents most of trivial shrinking algorithms from getting close to a minimum example, which would look something like ([-32768], [-1], [], [], []).
     */

    @Test("Bound5, Single")
    func bound5Single() {
        var report: ExhaustReport?
        let output = #exhaust(
            Bound5Fixture.gen,
            .randomOnly,
            .suppress(.issueReporting),
            .replay(16_799_307_796_119_368_455),
            .onReport { report = $0 },
            .logging(.debug),
            property: Bound5Fixture.property
        )
        if let report { print("[PROFILE] Bound5Single: \(report.profilingSummary)") }

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 1")
    func bound5Pathological() {
        let value = Bound5Fixture.Tuple(
            a: [-18914, -2906, 9816],
            b: [7672, 16087, 24512],
            c: [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885],
            d: [25982, 8828, 5007, -6389],
            e: [12744, -11152, -18025, -29069, 30825]
        )

        var report: ExhaustReport?
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.issueReporting),
            .reflecting(value),
            .onReport { report = $0 },
            property: Bound5Fixture.property
        )
        if let report { print("[PROFILE] Bound5Path1: \(report.profilingSummary)") }

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 2")
    func bound5Pathological2() {
        let value = Bound5Fixture.Tuple(
            a: [-10709],
            b: [29251, 31661],
            c: [-18678],
            d: [-2824, 15387, -15932, -23458, -6124, 3327, -21001, 16059, -21211, -27710],
            e: [16775, -32275, 813, 11044]
        )

        var report: ExhaustReport?
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.issueReporting),
            .reflecting(value),
            .onReport { report = $0 },
            property: Bound5Fixture.property
        )
        if let report { print("[PROFILE] Bound5Path2: \(report.profilingSummary)") }

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 3")
    func bound5Pathological3() throws {
        let value = Bound5Fixture.Tuple(
            a: [-11954, 25609, -21279],
            b: [20837, 6773, -1304, -13732, -2626, -3440, 15253, 28268, -31908, 30491],
            c: [23543, -10339, -12447, 9150, 18335, -2103, 15547, 11124],
            d: [-32635, 18394, -23954, 13750, 27692, 25639, 23372, -27650, 18759, 17794],
            e: [-6525, 2724, -30958, 28797, -2409, -1095, 2335, -14856]
        )
        var report: ExhaustReport?
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.issueReporting),
            .reflecting(value),
            .onReport { report = $0 },
            .logging(.debug, .keyValue),
            property: Bound5Fixture.property
        )

        let rep = try #require(report)
        #expect(rep.propertyInvocations == 89)
        #expect(rep.totalMaterializations == 372)

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 4")
    func bound5Pathological4() {
        let value = Bound5Fixture.Tuple(
            a: [10607, 11752, -7272, -15733],
            b: [],
            c: [14063, -27312, 2705],
            d: [-4862, 11017, 12831, 19004],
            e: [-25748, 8284, -13626, 12773, 4040]
        )
        var report: ExhaustReport?
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.all),
            .reflecting(value),
            .onReport { report = $0 },
            property: Bound5Fixture.property
        )
        if let report { print("[PROFILE] Bound5Path4: \(report.profilingSummary)") }

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, pathological 5")
    func bound5Pathological5() {
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.issueReporting),
            .replay(12_394_678_611_125_950_626),
            .logging(.debug, .jsonl),
            property: Bound5Fixture.property
        )

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, covering array time")
    func bound5CoveringArray() {
        let output = #exhaust(
            Bound5Fixture.gen,
            .suppress(.issueReporting),
            property: Bound5Fixture.property
        )

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, 52")
    func bound5Many() {
        let bound5s = #example(Bound5Fixture.gen, count: 100, seed: 1337)
            .filter { Bound5Fixture.property($0) == false }
        for bound5 in bound5s {
            let output = #exhaust(
                Bound5Fixture.gen,
                .suppress(.issueReporting),
                .reflecting(bound5),
                .randomOnly,
                property: Bound5Fixture.property
            )

            #expect(output?.arr.count == 2)
            #expect(output?.arr.sorted() == [-32768, -1])
        }
    }

    // MARK: Bound25

    /// This isn't exactly bound25 in that the property doesn't want all of them to be minimal, just that one is. It's here to test the BatchCrossSequenceRemovalSource
    @Test("Bound25!")
    func bound25() throws {
        let gen = #gen(Bound5Fixture.gen, Bound5Fixture.gen, Bound5Fixture.gen, Bound5Fixture.gen, Bound5Fixture.gen)
        let property: @Sendable (Bound5Fixture.Tuple) -> Bool = { tuple in
            if tuple.arr.isEmpty { return true }
            return tuple.arr.dropFirst().reduce(tuple.arr[0], &+) < 5 * 256
        }
        var report: ExhaustReport?
        let output = #exhaust(
            gen,
            .suppress(.issueReporting),
            .replay("B0ZF4ZX2NK312"),
            .onReport { report = $0 },
            .logging(.debug)
        ) { b25 in
            property(b25.0) &&
                property(b25.1) &&
                property(b25.2) &&
                property(b25.3) &&
                property(b25.4)
        }

        let rep = try #require(report)
        #expect(rep.propertyInvocations == 116)
        #expect(rep.totalMaterializations == 377)

        let b25 = try #require(output)
        let arr = b25.0.arr + b25.1.arr + b25.2.arr + b25.3.arr + b25.4.arr

        #expect(arr.count == 2)
        #expect(arr.sorted() == [-32768, -1])
    }
}
