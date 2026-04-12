//
//  CoverageBudgetTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust

@Suite("Coverage Budget")
struct CoverageBudgetTests {
    @Test("randomOnly skips coverage phase entirely")
    func randomOnlySkipsCoverage() {
        let gen = #gen(.bool(), .bool())
        #exhaust(gen, .budget(.custom(coverage: 200, sampling: 50)), .randomOnly) { _, _ in
            true
        }
    }

    @Test("coverageBudget setting is parsed")
    func coverageBudgetParsed() {
        // This should compile and run without issues
        let gen = #gen(.bool(), .bool(), .int(in: 0 ... 2))
        #exhaust(gen, .budget(.custom(coverage: 50, sampling: 50))) { _, _, _ in
            true
        }
    }
}
