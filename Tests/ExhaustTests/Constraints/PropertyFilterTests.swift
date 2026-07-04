//
//  PropertyFilterTests.swift
//  ExhaustTests
//
//  Property test for .filter that requires the Exhaust module.
//

import Exhaust
import Foundation
import Testing

@Suite("Generator Contracts — Filter")
struct GeneratorContractFilterTests {
    @Test("Filtered generator only produces values satisfying the predicate")
    func filterPostCondition() {
        let gen = #gen(.int(in: -1000 ... 1000)).filter { $0 > 0 }
        #exhaust(gen) { value in
            value > 0
        }
    }
}
