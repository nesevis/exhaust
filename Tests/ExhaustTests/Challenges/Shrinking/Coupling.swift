//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Coupling", .disabled("Disabled until edge encoder is in"))
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
    static let property: ([Int]) -> Bool = { arr in
        let result = arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i, arr[j] == i {
                return false
            }
            return true
        }
        print("Arr: \(arr) (\(result))")
        return result
    }

    @Test("Coupling")
    func couplingChallenge() throws {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                property: Self.property
            )
        )
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }

    @Test("Coupling Pathological 1")
    func couplingPathlogical1() throws {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug, .propertyTest: .debug], format: .human))
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                property: Self.property
            )
        )
        print()
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
}
