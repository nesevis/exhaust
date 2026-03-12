//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import ExhaustCore
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

    private static let gen: ReflectiveGenerator<Bound5> = {
        let arr = #gen(.int16(scaling: .linear).array(length: 0 ... 10))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return #gen(arr, arr, arr, arr, arr) { a, b, c, d, e in
            Bound5(a: a, b: b, c: c, d: d, e: e)
        }
    }()

    private static let property: (Bound5) -> Bool = { b5 in
        if b5.arr.isEmpty {
            return true
        }
        return b5.arr.dropFirst().reduce(b5.arr[0], &+) < 5 * 256
    }

    @Test("Bound5, Single")
    func bound5Single() throws {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        let output = #exhaust(Self.gen, .suppressIssueReporting, .replay(1337), property: Self.property)

        #expect(output?.arr.count == 2)
        #expect(output?.arr == [-1, -32768])
    }

    @Test("Bound5, Pathological 1")
    func bound5Pathological() throws {
        let value: Bound5 = .init(
            a: [-18914, -2906, 9816],
            b: [7672, 16087, 24512],
            c: [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885],
            d: [25982, 8828, 5007, -6389],
            e: [12744, -11152, -18025, -29069, 30825]
        )
        
        let output = #exhaust(
            Self.gen,
            .suppressIssueReporting,
            .reflecting(value),
            property: Self.property
        )

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 2")
    func bound5Pathological2() throws {
        let value: Bound5 = .init(
            a: [-10709],
            b: [29251, 31661],
            c: [-18678],
            d: [-2824, 15387, -15932, -23458, -6124, 3327, -21001, 16059, -21211, -27710],
            e: [16775, -32275, 813, 11044]
        )
        
        let output = #exhaust(
            Self.gen,
            .suppressIssueReporting,
            .reflecting(value),
            property: Self.property
        )

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, Pathological 3")
    func bound5Pathological3() throws {
        let value: Bound5 = .init(
            a: [-11954, 25609, -21279],
            b: [20837, 6773, -1304, -13732, -2626, -3440, 15253, 28268, -31908, 30491],
            c: [23543, -10339, -12447, 9150, 18335, -2103, 15547, 11124],
            d: [-32635, 18394, -23954, 13750, 27692, 25639, 23372, -27650, 18759, 17794],
            e: [-6525, 2724, -30958, 28797, -2409, -1095, 2335, -14856]
        )
        
        let output = #exhaust(
            Self.gen,
            .suppressIssueReporting,
            .reflecting(value),
            property: Self.property
        )

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }

    @Test("Bound5, 50")
    func bound5Many() throws {
        let bound5s = #extract(Self.gen, count: 100, seed: 1337)
            .filter { Self.property($0) == false }
        
        for bound5 in bound5s {
            let output = #exhaust(
                Self.gen,
                .suppressIssueReporting,
                .reflecting(bound5),
                property: Self.property
            )

            #expect(output?.arr.count == 2)
            #expect(output?.arr.sorted() == [-32768, -1])
        }
    }
    
    // MARK: - Types
    
    struct Bound5: Equatable {
        let a: [Int16]
        let b: [Int16]
        let c: [Int16]
        let d: [Int16]
        let e: [Int16]

        let arr: [Int16]

        init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            arr = a + b + c + d + e
        }
    }
}
