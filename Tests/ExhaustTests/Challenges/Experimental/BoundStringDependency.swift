//
//  BoundStringDependency.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

import Exhaust
import ExhaustTestSupport
import Testing

@Suite("Experimental Challenge: Dependent String", .tags(.challenge))
struct DependentStringChallenge {
    /// The generator returned from `bound` is irrelevant to the property, which only tests for length.
    @Test("Bound string dependency")
    func boundStringDependency() {
        let gen = #gen(.int(in: 0 ... 10)).bound(
            forward: { .string(length: $0 ... $0) },
            backward: \.count
        )

        let output = #exhaust(
            gen,
            .suppress(.issueReporting),
            .log(.debug)
        ) { value in
            !(4 ... 5 ~= value.count)
        }

        #expect(output == "    ")
    }
}
