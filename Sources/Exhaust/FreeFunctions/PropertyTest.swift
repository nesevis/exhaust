//
//  PropertyTest.swift
//  Exhaust
//
//  Created by Chris Kolbu on 30/7/2025.
//

enum PropertyTest {
    @discardableResult
    static func test<Output>(
        _ gen: ReflectiveGenerator<Output>,
        maxIterations: UInt64 = 100,
        seed: UInt64? = nil,
        uniqueMaxAttempts: UInt64? = nil,
        property: (Output) -> Bool,
    ) throws -> Output? {
        var iterations = 0
        var generator = ValueAndChoiceTreeInterpreter(
            gen,
            seed: seed,
            maxRuns: maxIterations,
            uniqueMaxAttempts: uniqueMaxAttempts,
        )
        var passFails = Dictionary([(true, [ChoiceTree?]()), (false, [ChoiceTree?]())], uniquingKeysWith: { $1 })

        while let (next, tree) = generator.next() {
            iterations += 1
            let passed = property(next)
            passFails[passed, default: []].append(tree)
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

                let successfulTraces = passFails[true]?.compactMap { $0 }.map { ChoiceSequence($0) } ?? []
                if let (shrunkSequence, shrunkValue) = try Interpreters.reduce(
                    gen: gen,
                    tree: tree,
                    config: .fast,
//                    successfulTraces: successfulTraces,
                    property: property
                ) {
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "shrunk_counterexample",
                        "\(shrunkValue)"
                    )
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "counterexample_diff",
                        CounterexampleDiff.format(original: next, shrunk: shrunkValue)
                    )
                    ExhaustLog.notice(
                        category: .propertyTest,
                        event: "shrunk_blueprint",
                        "\(shrunkSequence.shortString)"
                    )
                    return shrunkValue
                }
                return nil
            }
        }
        ExhaustLog.notice(
            category: .propertyTest,
            event: "property_passed",
            metadata: [
                "iterations": "\(maxIterations)",
            ],
        )
        return nil
    }
}
