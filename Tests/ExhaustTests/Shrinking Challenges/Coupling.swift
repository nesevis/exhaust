//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
import ExhaustCore

@MainActor
@Suite("Shrinking Challenge: Coupling")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */

    /// This generator is not reflective due to the bind
    static let gen: ReflectiveGenerator<[Int]> = #gen(.int(in: 0 ... 100))
        .bind { n in
            Gen.arrayOf(Gen.choose(in: 0 ... n), within: 2 ... max(2, UInt64(n) + 1))
        }
        .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

    /// The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
    static let property: ([Int]) -> Bool = { arr in
        arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i, arr[j] == i {
                return false
            }
            return true
        }
    }

    @Test("Coupling")
    func couplingBatch() throws {
        let value = try #require(#exhaust(Self.gen, .suppressIssueReporting, property: Self.property))
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
}
