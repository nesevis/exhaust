//
//  PropertyTest.swift
//  Exhaust
//
//  Created by Chris Kolbu on 30/7/2025.
//

enum PropertyTest {
    static func test<Output>(
        _ gen: ReflectiveGenerator<Output>,
        maxIterations: UInt64 = 100,
        seed: UInt64? = nil,
        property: @escaping (Output) -> Bool,
    ) throws {
        var iterations = 0
        var generator = ValueInterpreter(gen, seed: seed, maxRuns: maxIterations)
        var passFails = Dictionary([(true, [ChoiceTree?]()), (false, [ChoiceTree?]())], uniquingKeysWith: { $1 })

        while let next = generator.next() {
            iterations += 1
            let passed = property(next)
            let reflection = try Interpreters.reflect(gen, with: next)
            passFails[passed]?.append(reflection)
            if passed == false {
                ExhaustLog.error(
                    category: .propertyTest,
                    event: "property_failed",
                    metadata: [
                        "iteration": "\(iterations)",
                        "max_iterations": "\(maxIterations)",
                    ],
                )
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "counterexample",
                    "\(next)",
                )
                ExhaustLog.notice(
                    category: .propertyTest,
                    event: "reflected_blueprint",
                    reflection?.debugDescription ?? "nil",
                )
                // TODO: Add seed and size
                return
            }
        }
        ExhaustLog.notice(
            category: .propertyTest,
            event: "property_passed",
            metadata: [
                "iterations": "\(maxIterations)",
            ],
        )
    }
}
