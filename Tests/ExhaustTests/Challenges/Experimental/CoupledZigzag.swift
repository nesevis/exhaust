//
//  CoupledZigzag.swift
//  Exhaust
//
//  Created by Chris Kolbu on 26/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Experimental Challenge: Coupled Zigzag")
struct CoupledZigzagChallenge {
    /*
     Two coordinates coupled by the property but structurally separated
     so that tandem reduction cannot group them. m is the bind-inner
     value; n is in the bound subtree. The CDG has a Kleisli edge from
     m to n, but the bound generator is independent of m (n's range
     doesn't depend on m), so Kleisli's upstream search has no
     structural leverage — each upstream value produces the same
     downstream generator.

     The coupling constraint abs(m - n) <= 1 with m >= 10 means
     per-coordinate binary search can only move each by ~1 per cycle.
     The oscillation damping pass detects this slow convergence and
     proposes a joint binary search.

     Expected smallest counterexample: (10, 9)
     */

    @Test("Coupled zigzag via bind")
    func coupledZigzag() throws {
        let gen = #gen(.int(in: 0 ... 500))
            .bind { m in
                #gen(.int(in: 0 ... 500)).map { n in (m, n) }
            }

        let property: @Sendable ((Int, Int)) -> Bool = { pair in
            let (m, n) = pair
            guard abs(Int(m) - Int(n)) <= 1 else { return true }
            guard m >= 10 else { return true }
            return false
        }

        let counterExample = (10, 9)
        #expect(property(counterExample) == false)

        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting,
                .replay(12768154885595245120),
                .reducer(.choiceGraph),
                .onReport { report = $0 },
                .logging(.debug, .keyValue),
                property: property
            )
        )
        if let report {
            print("[PROFILE] CoupledZigzag: \(report.profilingSummary)")
            print("[PROFILE] Cycles: \(report.cycles)")
        }

        #expect(value == counterExample)
    }

    @Test("Coupled zigzag via nested bind (oscillation damping)")
    func coupledZigzagNestedBind() throws {
        // Nested binds separate m and n into different bind containers:
        // [outer_bind, val(m), inner_bind, val(n), just, /inner_bind, /outer_bind]
        //
        // This prevents tandem grouping (m and n are not siblings — they're
        // in different containers). Redistribution moves them in opposite
        // directions (breaks abs(m-n) <= 1). Per-coordinate binary search
        // can only move each by ~1 per cycle.
        //
        // The oscillation damping pass is the primary mechanism for breaking
        // the zigzag: it detects both values moving slowly toward zero and
        // proposes a joint binary search that converges in O(log n) probes.
        let gen = #gen(.int(in: 0 ... 10000))
            .bind { (m: Int) -> ReflectiveGenerator<(Int, Int)> in
                #gen(.int(in: 0 ... 10000)).bind { (n: Int) -> ReflectiveGenerator<(Int, Int)> in
                    .just((m, n))
                }
            }

        let property: @Sendable ((Int, Int)) -> Bool = { pair in
            let (m, n) = pair
            guard abs(Int(m) - Int(n)) <= 1 else { return true }
            guard m >= 10 else { return true }
            return false
        }

        let counterExample = (10, 9)
        #expect(property(counterExample) == false)

        var report: ExhaustReport?
        let value = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting,
                .budget(.exorbitant),
                .replay(15376868453505688755),
                .onReport { report = $0 },
                .reducer(.choiceGraph),
                property: property
            )
        )
        if let report {
            print("[PROFILE] CoupledZigzagNested: \(report.profilingSummary)")
            print("[PROFILE] Cycles: \(report.cycles)")
        }

        #expect(value == counterExample)
    }
}
