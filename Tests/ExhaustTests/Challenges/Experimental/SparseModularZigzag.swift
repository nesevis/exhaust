//
//  SparseModularZigzag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: Sparse Modular Zigzag")
struct SparseModularZigzagChallenge {
    /*
     A challenge designed to attack multiple reducer weak points simultaneously:

     1. Zigzag coupling: m and n must stay within 1 of each other (oscillation
        damping territory — per-coordinate binary search moves each by O(1)
        per cycle).
     2. Bind restructuring: array length depends on (m + n) % 4 + 2, so
        reducing m or n can change the downstream structure mid-search.
     3. Sparse validity: the modular constraint (m * n) % 31 < 3 eliminates
        ~90% of (m, n) pairs, so most mutations land outside the failure
        surface.
     4. Cross-fibre coupling: the array must sum to at least m, coupling
        array content to the upstream value being reduced.
     5. Non-monotone landscape: the modular constraint creates islands of
        validity separated by large rejection gaps, defeating binary search's
        monotonicity assumption.

     The minimal counterexample is the smallest (m, n) satisfying all
     constraints with the shortest valid array. Finding it requires the
     reducer to simultaneously navigate the zigzag, survive structural
     changes at mod-4 boundaries, hop between modular islands, and keep
     the array sum valid.
     */

    static let gen = #gen(
        .int(in: 0 ... 500),
        .int(in: 0 ... 500)
    ).bind { m, n in
        let length = (m + n) % 4 + 2
        return #gen(.int(in: 1 ... max(1, n)).array(length: length ... length))
            .map { arr in (m, n, arr) }
    }

    static let property: @Sendable ((Int, Int, [Int])) -> Bool = { input in
        let (m, n, arr) = input

        // Constraint 1: zigzag coupling
        guard abs(Int(m) - Int(n)) <= 1 else { return true }

        // Constraint 2: blocks trivial zeroing
        guard m >= 15 else { return true }

        // Constraint 3: sparse modular filter (~10% of pairs)
        guard (m * n) % 31 < 3 else { return true }

        // Constraint 4: array elements must be positive (guaranteed by range)
        // and sum must reach m
        guard arr.reduce(0, +) >= m else { return true }

        // All constraints met — property fails
        return false
    }

    /// It is completely stuck at n=23, but there IS a smaller counterexample: (18, 19) since 18 * 19 % 31 = 1 < 3.
    /// The reducer can't reach it because every value between 19 and 23 fails (m * n) % 31 < 3 — there's no monotone path. Binary search, redistribution, and Kleisli composition all try nearby values and hit the 90% rejection wall.
    /// This is the non-monotone gap problem at scale. The linearScan encoder handles small gaps (remaining range ≤ 64), but the gap from 23 to 18 in the modular landscape is too wide for it to bridge, and the coordinates are coupled so it can't scan them independently.
    @Test("Sparse modular zigzag")
    func sparseModularZigzag() throws {
        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                Self.gen,
                .suppressIssueReporting,
                .budget(.exorbitant),
                .replay(11_933_936_430_368_835_868),
                .onReport { report = $0 },
                .logging(.debug),
                property: Self.property
            )
        )
        if let report { print("[PROFILE] SparseModularZigzag: \(report.profilingSummary)") }

        let (m, n, arr) = value

        // Verify the counterexample satisfies all constraints.
        #expect(abs(Int(m) - Int(n)) <= 1)
        #expect(m >= 15)
        #expect((m * n) % 31 < 3)
        #expect(arr.reduce(0, +) >= m)

        // The minimal m satisfying m >= 15 and (m * m) % 31 < 3 or (m * (m±1)) % 31 < 3.
        print("Minimal counterexample: m=\(m), n=\(n), arr=\(arr)")
    }
}
