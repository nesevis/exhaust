//
//  BoundaryCoverageIntegrationTests.swift
//  Exhaust
//

import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Boundary Coverage Integration")
struct BoundaryCoverageIntegrationTests {
    @Test("Boundary covering array finds failure at int boundary")
    func findsFailureAtBoundary() {
        // Failure when first parameter is 0 and second is 10000
        // Random at 100 samples: P(hit) ≈ 100 / (5 * 5) = 100/25 per boundary pair
        // but among full range: 100 / (10001^2) ≈ 0.0001%
        let gen = #gen(.int(in: 0 ... 10000), .int(in: 0 ... 10000))
        let result = #exhaust(gen, .samplingBudget(100), .suppressIssueReporting) { a, b in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Boundary coverage should find (0, 10000)")
    }

    @Test("Three-parameter boundary interaction is found")
    func threeParamBoundaryInteraction() {
        let gen = #gen(.int(in: 0 ... 10000), .int(in: 0 ... 10000), .int(in: 0 ... 10000))
        let result = #exhaust(gen, .samplingBudget(10), .suppressIssueReporting) { a, b, _ in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Boundary coverage should find the (0, 10000) pair")
    }
}
