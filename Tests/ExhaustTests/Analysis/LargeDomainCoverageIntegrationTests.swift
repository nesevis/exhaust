//
//  LargeDomainCoverageIntegrationTests.swift
//  Exhaust
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Large Domain Coverage Integration")
struct LargeDomainCoverageIntegrationTests {
    @Test("Problematic-value covering array finds failure at an int problematic value")
    func coveringArrayFindsFailureAtIntProblematicValue() {
        // Failure when first parameter is 0 and second is 10000
        // Random at 100 samples: P(hit) ≈ 100 / (5 * 5) = 100/25 per problematic-value pair
        // but among full range: 100 / (10001^2) ≈ 0.0001%
        let gen = #gen(.int(in: 0 ... 10000), .int(in: 0 ... 10000))
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting)) { a, b in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Problematic-value coverage should find (0, 10000)")
    }

    @Test("Three-parameter problematic-value interaction is found")
    func threeParameterProblematicValueInteractionIsFound() {
        let gen = #gen(.int(in: 0 ... 10000), .int(in: 0 ... 10000), .int(in: 0 ... 10000))
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting)) { a, b, _ in
            !(a == 0 && b == 10000)
        }
        #expect(result != nil, "Problematic-value coverage should find the (0, 10000) pair")
    }

    @Test("String problematic-value coverage finds supplementary plane character")
    func stringProblematicValueCoverageFindsSupplementaryPlaneCharacter() {
        let gen = #gen(.string(length: 1 ... 5))
        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting), .log(.debug)) { str in
            str.count == str.utf16.count
        }
        #expect(result != nil, "Problematic-value coverage should find a string where count != utf16.count")
    }

    @Test("String problematic-value coverage respects CharacterSet membership")
    func stringProblematicValueCoverageRespectsCharacterSetMembership() {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "*-._"))
        let gen = #gen(.string(from: allowed, length: 1 ... 6))

        let result = #exhaust(gen, .budget(.custom(coverage: 2000, sampling: 0)), .suppress(.issueReporting)) { str in
            str.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        #expect(result == nil, "Problematic-value coverage should not inject characters outside the CharacterSet")
    }
}
