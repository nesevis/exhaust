//
//  BoundaryCoverageIntegrationTests.swift
//  Exhaust
//

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
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting)) { a, b in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Boundary coverage should find (0, 10000)")
    }

    @Test("Three-parameter boundary interaction is found")
    func threeParamBoundaryInteraction() {
        let gen = #gen(.int(in: 0 ... 10000), .int(in: 0 ... 10000), .int(in: 0 ... 10000))
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting)) { a, b, _ in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Boundary coverage should find the (0, 10000) pair")
    }

    @Test("String boundary coverage finds supplementary plane character")
    func stringBoundaryFindsSupplementaryPlaneCharacter() {
        let gen = #gen(.string(length: 1 ... 5))
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting), .logging(.debug)) { str in
            str.count == str.utf16.count
        }
        #expect(result != nil, "Boundary coverage should find a string where count != utf16.count")
    }
}
