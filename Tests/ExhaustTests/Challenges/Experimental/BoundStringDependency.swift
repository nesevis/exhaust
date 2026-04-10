//
//  BoundStringDependency.swift
//  Exhaust
//
//  Created by Chris Kolbu on 13/3/2026.
//

import Exhaust
import Testing

@Suite("Experimental Challenge: Dependent String")
struct DependentStringChallenge {
    /**
     The generator returned from `bound` is irrelevant to the property, which only tests for length
     */
    @Test("Bound string dependency", .disabled("FIXME: Does not terminate in ChoiceGraph"))
    func boundStringDependency() {
        let gen = #gen(.int(in: 0 ... 10)).bound(
            forward: { .string(length: UInt64($0) ... UInt64($0)) },
            backward: \.count
        )

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .logging(.debug),
            .reducer(.bonsai)
        ) { value in
            !(4 ... 5 ~= value.count)
        }

        #expect(output == "    ")
    }
}
