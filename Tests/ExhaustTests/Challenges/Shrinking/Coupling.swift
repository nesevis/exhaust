//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Exhaust
import ExhaustTestSupport
import Foundation
import Testing

@MainActor
@Suite("Shrinking Challenge: Coupling", .tags(.challenge))
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */

    /// This generator is not reflective due to the bind
    static let gen = #gen(.int(in: 0 ... 10))
        .bind { n in
            #gen(.int(in: 0 ... n)).array(length: 2 ... max(2, n + 1))
        }
        .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

    /// The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
    static let property: @Sendable ([Int]) -> Bool = { arr in
        arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i, arr[j] == i {
                return false
            }
            return true
        }
    }

    @Test
    func coupling() throws {
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppress(.issueReporting),
                .log(.debug),
                .replay(1546),
                property: Self.property
            )
        )
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }

    @Test("Coupling Pathological 1")
    func couplingPathological1() throws {
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppress(.issueReporting),
                property: Self.property
            )
        )
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }

    @Test("Coupling Pathological 2")
    func couplingPathological2() throws {
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppress(.issueReporting),
                .log(.debug),
                property: Self.property
            )
        )
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
}
