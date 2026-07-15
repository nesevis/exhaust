import ExhaustCore
import Testing

@Suite("Approximation safety")
struct ApproximationSafetyTests {
    @Test(
        "Transform kinds preserve their domains and source directions",
        arguments: approximateTransformFixtures
    )
    func transformKindsPreserveDomainsAndDirections(
        fixture: ApproximateTransformFixture
    ) throws {
        let derivativeDirections = try collectDerivativeDirections(fixture)
        #expect(
            derivativeDirections.isSuperset(of: fixture.requiredDirections),
            "Derivative sampling missed \(fixture.requiredDirections.subtracting(derivativeDirections)) for \(fixture.name)"
        )

        let onlineDirections = try collectOnlineDirections(fixture)
        #expect(
            onlineDirections.isSuperset(of: fixture.requiredDirections),
            "Online CGS missed \(fixture.requiredDirections.subtracting(onlineDirections)) for \(fixture.name)"
        )
    }
}

// MARK: - Fixtures

struct ApproximateTransformFixture: Sendable, CustomStringConvertible {
    let name: String
    let buildGenerator: @Sendable () -> AnyGenerator
    let observe: @Sendable (Any) -> Set<ApproximateTransformDirection>?
    let requiredDirections: Set<ApproximateTransformDirection>

    var description: String {
        name
    }
}

enum ApproximateTransformDirection: String, Hashable, Sendable {
    case sourceLower
    case sourceUpper
    case dependentLower
    case dependentUpper
}

private let approximateTransformFixtures: [ApproximateTransformFixture] = [
    .init(
        name: "transform.map",
        buildGenerator: {
            ReflectiveGenerator(
                Gen.choose(in: 0 ... 10 as ClosedRange<Int>)
            ).map { $0 + 100 }.gen.erase()
        },
        observe: { output in
            guard let value = output as? Int,
                  (100 ... 110).contains(value)
            else {
                return nil
            }
            return boundaryDirections(
                value - 100,
                lower: .sourceLower,
                upper: .sourceUpper
            )
        },
        requiredDirections: [.sourceLower, .sourceUpper]
    ),
    .init(
        name: "transform.isomorph",
        buildGenerator: {
            Gen.zip(
                Gen.choose(in: 0 ... 10 as ClosedRange<Int>),
                Gen.choose(in: 0 ... 10 as ClosedRange<Int>)
            ).erase()
        },
        observe: { output in
            guard let values = output as? (Int, Int),
                  (0 ... 10).contains(values.0),
                  (0 ... 10).contains(values.1)
            else {
                return nil
            }
            return boundaryDirections(
                values.0,
                lower: .sourceLower,
                upper: .sourceUpper
            ).union(boundaryDirections(
                values.1,
                lower: .dependentLower,
                upper: .dependentUpper
            ))
        },
        requiredDirections: [
            .sourceLower,
            .sourceUpper,
            .dependentLower,
            .dependentUpper,
        ]
    ),
    .init(
        name: "transform.bind",
        buildGenerator: {
            ReflectiveGenerator(
                Gen.choose(in: 0 ... 10 as ClosedRange<Int>)
            ).bind { source in
                ReflectiveGenerator(Gen.zip(
                    Gen.just(source),
                    Gen.choose(in: source ... (source + 10))
                ))
            }.gen.erase()
        },
        observe: { output in
            guard let values = output as? (Int, Int),
                  (0 ... 10).contains(values.0),
                  (values.0 ... (values.0 + 10)).contains(values.1)
            else {
                return nil
            }
            return boundaryDirections(
                values.0,
                lower: .sourceLower,
                upper: .sourceUpper
            ).union(boundaryDirections(
                values.1 - values.0,
                lower: .dependentLower,
                upper: .dependentUpper
            ))
        },
        requiredDirections: [
            .sourceLower,
            .sourceUpper,
            .dependentLower,
            .dependentUpper,
        ]
    ),
    .init(
        name: "transform.metamorphic",
        buildGenerator: {
            ReflectiveGenerator(
                Gen.choose(in: 0 ... 10 as ClosedRange<Int>)
            ).metamorph { $0 + 100 }.gen.erase()
        },
        observe: { output in
            guard let values = output as? (Int, Int),
                  (0 ... 10).contains(values.0),
                  values.1 == values.0 + 100
            else {
                return nil
            }
            return boundaryDirections(
                values.0,
                lower: .sourceLower,
                upper: .sourceUpper
            )
        },
        requiredDirections: [.sourceLower, .sourceUpper]
    ),
]

// MARK: - Sampling

private func collectDerivativeDirections(
    _ fixture: ApproximateTransformFixture
) throws -> Set<ApproximateTransformDirection> {
    var observedDirections: Set<ApproximateTransformDirection> = []
    let generator = fixture.buildGenerator()

    for sampleIndex in UInt64(0) ..< 128 {
        var randomNumberGenerator = Xoshiro256.derive(
            from: 42,
            at: sampleIndex
        )
        guard let output = try CGSDerivativeInterpreter.sample(
            generator,
            using: &randomNumberGenerator,
            size: 100
        ),
            let directions = fixture.observe(output)
        else {
            Issue.record("Derivative sampling produced an out-of-domain value for \(fixture.name)")
            return observedDirections
        }
        observedDirections.formUnion(directions)
    }

    return observedDirections
}

private func collectOnlineDirections(
    _ fixture: ApproximateTransformFixture
) throws -> Set<ApproximateTransformDirection> {
    var observedDirections: Set<ApproximateTransformDirection> = []
    var interpreter = OnlineCGSInterpreter(
        fixture.buildGenerator(),
        predicate: { _ in false },
        sampleCount: 16,
        seed: 42,
        maxRuns: 128
    )

    while let output = try interpreter.next() {
        guard let directions = fixture.observe(output) else {
            Issue.record("Online CGS produced an out-of-domain value for \(fixture.name)")
            return observedDirections
        }
        observedDirections.formUnion(directions)
    }

    return observedDirections
}

private func boundaryDirections(
    _ value: Int,
    lower: ApproximateTransformDirection,
    upper: ApproximateTransformDirection
) -> Set<ApproximateTransformDirection> {
    var directions: Set<ApproximateTransformDirection> = []
    if value <= 4 {
        directions.insert(lower)
    }
    if value >= 6 {
        directions.insert(upper)
    }
    return directions
}
