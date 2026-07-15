import ExhaustCore
import ExhaustTestSupport
import Foundation
import Testing

/// Smoke coverage for the self-fuzzing oracle roster: on a healthy build, no generated case may violate any oracle. A violation here is either a real engine defect or an over-strict oracle — both need a human look before the harness can trust the roster.
@Suite("MetaFuzz oracles")
struct MetaFuzzOracleTests {
    @Test(
        "Every generator operation satisfies the exact MetaFuzz laws",
        arguments: metaFuzzOperationFixtures
    )
    func operationFixturesSatisfyExactLaws(
        fixture: MetaFuzzOperationFixture
    ) throws {
        try MetaFuzz.checkOperationFixture(fixture)
    }

    @Test(
        "Every generator operation remains total and well-typed under approximation",
        arguments: metaFuzzOperationFixtures
    )
    func operationFixturesSatisfyApproximationSafety(
        fixture: MetaFuzzOperationFixture
    ) throws {
        try MetaFuzz.checkApproximationFixture(fixture)
    }

    @Test(
        "Every supported generator operation survives screening materialization",
        arguments: metaFuzzOperationFixtures
    )
    func operationFixturesSatisfyScreeningMaterialization(
        fixture: MetaFuzzOperationFixture
    ) throws {
        try MetaFuzz.checkScreeningFixture(fixture)
    }

    @Test("No oracle fires on healthy code across generated cases", arguments: [1, 2])
    func oraclesHoldOnHealthyCode(maxDepth: Int) throws {
        let caseGen = MetaFuzz.caseGenerator(maxDepth: maxDepth)
        var iterator = ValueInterpreter(caseGen.gen, seed: 42, maxRuns: 60)
        var checked = 0
        while let fuzzCase = try iterator.next() {
            do {
                try MetaFuzz.check(fuzzCase)
                checked += 1
            } catch {
                Issue.record("Oracle fired on healthy code: \(error) — case: \(fuzzCase)")
                return
            }
        }
        #expect(checked > 0, "The case generator must produce checkable cases")
    }

    @Test("Tuned filter laws compare one stable generator identity")
    func tunedFilterLawsUseStableGeneratorIdentity() throws {
        let recipe = GenRecipe.combinator(.filtered(
            .combinator(.oneOf([
                .leaf(.int(-18 ... 34)),
                .leaf(.int(-99 ... 80)),
                .leaf(.int(43 ... 79)),
            ])),
            .isEven
        ))

        try MetaFuzz.check(MetaFuzzCase(
            recipe: recipe,
            valueSeed: 9_223_372_036_854_775_887,
            perturbationSeed: 8_260_363_646_961_457_174
        ))
    }

    @Test("Case generation is deterministic under a pinned seed")
    func caseGenerationIsDeterministic() throws {
        let first = try describeCases(seed: 7)
        let second = try describeCases(seed: 7)
        #expect(first == second)
        #expect(first.isEmpty == false)
    }

    @Test("Frozen records round-trip and replay")
    func frozenRecordRoundTrip() throws {
        let caseGen = MetaFuzz.caseGenerator(maxDepth: 2)
        var iterator = ValueInterpreter(caseGen.gen, seed: 3, maxRuns: 10)
        var replayed = 0
        while let fuzzCase = try iterator.next() {
            let data = try MetaFuzz.freeze(
                fuzzCase,
                violation: DeterminismViolation("fixture"),
                note: "round-trip fixture"
            )
            let record = try JSONDecoder().decode(MetaFuzzFrozenCase.self, from: data)
            #expect(record.oracle == "DeterminismViolation")
            #expect(record.kind == .pipelineCase)
            try MetaFuzz.replay(data)
            replayed += 1
        }
        #expect(replayed > 0)
    }

    @Test("Replay rejects a stale schema version")
    func replayRejectsStaleVersion() throws {
        let caseGen = MetaFuzz.caseGenerator(maxDepth: 1)
        var iterator = ValueInterpreter(caseGen.gen, seed: 3, maxRuns: 1)
        let fuzzCase = try #require(try iterator.next())
        let data = try MetaFuzz.freeze(fuzzCase, violation: DeterminismViolation("fixture"))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 999
        let stale = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: FrozenCaseVersionMismatch.self) {
            try MetaFuzz.replay(stale)
        }
    }
}

// MARK: - Helpers

private func describeCases(seed: UInt64) throws -> [String] {
    let caseGen = MetaFuzz.caseGenerator(maxDepth: 1)
    var iterator = ValueInterpreter(caseGen.gen, seed: seed, maxRuns: 10)
    var descriptions: [String] = []
    while let fuzzCase = try iterator.next() {
        descriptions.append(fuzzCase.description)
    }
    return descriptions
}
