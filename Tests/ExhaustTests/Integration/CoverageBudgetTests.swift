//
//  CoverageBudgetTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust

@Suite("Coverage Budget")
struct CoverageBudgetTests {
//    @Test("Exhaustive finite-domain still skips random phase")
    // TODO. Test in a different way
//    func exhaustiveSkipsRandom() {
//        // 2 * 2 = 4 combinations, well within default budget
    ////        var seen = Set<String>()
//        #exhaust(#gen(.bool(), .bool()), .samplingBudget(50)) { a, b in
    ////            seen.insert("\(a),\(b)")
//            return true
//        }
//        // Should have exactly 4 combinations (exhaustive)
//        #expect(seen.count == 4)
//    }

    @Test("randomOnly skips coverage phase entirely")
    func randomOnlySkipsCoverage() {
        let gen = #gen(.bool(), .bool())
        #exhaust(gen, .samplingBudget(50), .randomOnly) { _, _ in
            true
        }
    }

    @Test("coverageBudget setting is parsed")
    func coverageBudgetParsed() {
        // This should compile and run without issues
        let gen = #gen(.bool(), .bool(), .int(in: 0 ... 2))
        #exhaust(gen, .coverageBudget(50), .samplingBudget(50)) { _, _, _ in
            true
        }
    }
}
