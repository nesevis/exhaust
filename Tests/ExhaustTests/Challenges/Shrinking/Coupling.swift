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
@Suite("Shrinking Challenge: Coupling")
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
        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                .onReport { report = $0 },
                .logging(.debug, .keyValue),
//                .reducer(.choiceGraph),
                .replay(1546),
                property: Self.property
            )
        )
        if let report { print("[PROFILE] Coupling: \(report.profilingSummary)") }
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }

    @Test("Coupling Pathological 1")
    func couplingPathlogical1() throws {
        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                .onReport { report = $0 },
                property: Self.property
            )
        )
        if let report { print("[PROFILE] CouplingPath: \(report.profilingSummary)") }
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
    
    @Test("Coupling Pathological 2")
    func couplingPathlogical2() throws {
        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                .onReport { report = $0 },
                .reducer(.choiceGraph),
                .logging(.debug, .keyValue),
                property: Self.property
            )
        )
        if let report { print("[PROFILE] CouplingPath: \(report.profilingSummary)") }
        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
}
