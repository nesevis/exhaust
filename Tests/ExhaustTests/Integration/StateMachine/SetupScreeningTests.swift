import ExhaustCore
import Testing
@testable import Exhaust

// MARK: - Setup Argument Coverage

@Suite("@Setup arguments join the screening covering array", .tags(.stateMachine))
struct SetupScreeningTests {
    @Test("Each setup argument becomes its own covering-array factor")
    func setupArgumentsBecomeSeparateFactors() throws {
        let factors = try #require(__ExhaustRuntime.setupScreeningFactors(for: TwoArgumentSetupSpec.self))
        // One factor per argument: the `Int` range and the array, the latter as a composite (length, elements) factor.
        #expect(factors.domainSizes.count == 2)
        #expect(factors.domainSizes.allSatisfy { $0 > 1 }, "A factor with one level covers nothing: \(factors.domainSizes)")
    }

    @Test("A zero-setup spec contributes no factors, leaving the covering array unchanged")
    func zeroSetupSpecContributesNoFactors() {
        #expect(__ExhaustRuntime.setupScreeningFactors(for: NoSetupSpec.self) == nil)
    }

    @Test("Screening rows vary the setup arguments rather than repeating one value")
    func screeningRowsVarySetupArguments() throws {
        let factors = try #require(__ExhaustRuntime.setupScreeningFactors(for: TwoArgumentSetupSpec.self))
        let setupGen = try #require(TwoArgumentSetupSpec.setupGenerator)
        let generator = BalancedCoveringArrayGenerator(domainSizes: factors.domainSizes)

        var steps: [String] = []
        for _ in 0 ..< 12 {
            guard let row = generator.next(), let tree = factors.buildTree(row) else {
                break
            }
            let combined = try #require(__ExhaustRuntime.combineScreeningCandidate(
                TwoArgumentSetupSpec.self,
                setupTree: tree,
                taggedCommands: [(.prefix, .touch)],
                commandTree: .just
            ))
            let step = try #require(combined.value.setupStep)
            steps.append("\(step)")
        }

        #expect(steps.count >= 8)
        #expect(Set(steps).count >= 6, "Covering array rows should spread across setup values, got \(Set(steps))")
        // The composed candidate tree must be decomposable again, or reduction cannot separate the two halves.
        #expect(steps.allSatisfy { $0.hasPrefix("configure(") })
    }

    @Test("Screening reaches a failure that needs a specific setup value paired with a specific command")
    func screeningReachesSetupCommandInteraction() async throws {
        // `rare` only fails at capacity 7. Sampling has to draw that pair by luck; a covering array that treats the
        // setup argument as a factor pairs every capacity with every command type, so screening reaches it directly.
        let result = try #require(
            await #execute(
                InteractionSpec.self,
                .commandLimit(4),
                .budget(.custom(screening: 60, sampling: 0)),
                .suppress(.issueReporting)
            )
        )
        #expect(result.discoveryMethod == .screening)
        let setup = try #require(result.setup)
        guard case let .configure(capacity) = setup else {
            Issue.record("Expected a configure setup step, got \(setup)")
            return
        }
        #expect(capacity == 7)
        #expect(result.commands.contains { "\($0)" == "rare" })
    }

    @Test("A deterministic setup is applied during screening probes")
    func deterministicSetupAppliedDuringScreening() async {
        // A zero-parameter @Setup synthesizes a deterministic generator, which has no parameters for the covering-array
        // analysis to extract. Screening must still apply it: this spec only fails when a probe runs before setup.
        let result = await #execute(
            DeterministicSetupSpec.self,
            .commandLimit(4),
            .budget(.custom(screening: 40, sampling: 0)),
            .suppress(.issueReporting)
        )
        #expect(result == nil, "Screening probed an unconfigured spec: \(String(describing: result?.trace))")
    }

    @Test("A deterministic setup contributes a zero-factor leading block rather than none")
    func deterministicSetupContributesZeroFactorBlock() throws {
        let factors = try #require(__ExhaustRuntime.setupScreeningFactors(for: DeterministicSetupSpec.self))
        #expect(factors.domainSizes.isEmpty)
        // The block's one tree is what keeps every screening candidate carrying a setup step.
        #expect(factors.buildTree(CoveringArrayRow(values: [])) != nil)
    }

    @Test("Setup factor domains do not depend on the screening budget")
    func setupFactorDomainsAreBudgetIndependent() throws {
        // A `U-{N}` replay runs under a different budget than discovery. Budget-dependent factor domains would build a
        // different covering array and land the replay on a different row.
        let first = try #require(__ExhaustRuntime.setupScreeningFactors(for: TwoArgumentSetupSpec.self))
        let second = try #require(__ExhaustRuntime.setupScreeningFactors(for: TwoArgumentSetupSpec.self))
        #expect(first.domainSizes == second.domainSizes)
    }
}

// MARK: - Test Specs

@StateMachine
private final class TwoArgumentSetupSpec {
    var capacity = 0
    var preload: [Int] = []
    @SystemUnderTest var box = CountingBox()

    @Setup(.int(in: 1 ... 32), .int(in: 0 ... 9).array(length: 0 ... 4))
    func configure(capacity: Int, preload: [Int]) {
        self.capacity = capacity
        self.preload = preload
    }

    @Command(weight: 1)
    func touch() throws {}

    func failureDescription() -> String? {
        nil
    }
}

@StateMachine
private final class NoSetupSpec {
    @SystemUnderTest var box = CountingBox()

    @Command(weight: 1)
    func touch() throws {}

    func failureDescription() -> String? {
        nil
    }
}

@StateMachine
private final class DeterministicSetupSpec {
    var configured = false
    @SystemUnderTest var box = CountingBox()

    @Setup
    func configure() {
        configured = true
    }

    @Command(weight: 1, .int(in: 0 ... 3))
    func poke(value _: Int) throws {
        try check(configured, "command ran before setup was applied")
    }

    @Command(weight: 1)
    func touch() throws {
        try check(configured, "command ran before setup was applied")
    }

    func failureDescription() -> String? {
        "configured: \(configured)"
    }
}

@StateMachine
private final class InteractionSpec {
    var capacity = 0
    @SystemUnderTest var box = CountingBox()

    @Setup(.int(in: 1 ... 8))
    func configure(capacity: Int) {
        self.capacity = capacity
        box.value = capacity
    }

    @Command(weight: 1)
    func common() throws {}

    @Command(weight: 1)
    func rare() throws {
        try check(box.value != 7, "rare command at capacity 7")
    }

    func failureDescription() -> String? {
        "capacity: \(capacity)"
    }
}

// MARK: - Supporting Types

private final class CountingBox {
    var value = 0
}
