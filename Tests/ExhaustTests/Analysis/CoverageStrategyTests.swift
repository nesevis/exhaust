import ExhaustCore
import Testing

// MARK: - Exhaustive Strategy

@Suite("ExhaustiveCoverageStrategy")
struct ExhaustiveCoverageStrategyTests {
    @Test("Returns covering when totalSpace fits within budget and no binds")
    func fitsWithinBudget() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(in: 0 ... 2)
        )))
        let strategy = ExhaustiveCoverageStrategy(hasBinds: false)
        let covering = strategy.generate(profile: profile, budget: 10)
        #expect(covering != nil)
        #expect(covering?.strength == 2)
        #expect(covering?.rows.count == 6)
    }

    @Test("Returns nil when totalSpace exceeds budget")
    func exceedsBudget() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(in: 0 ... 2)
        )))
        let strategy = ExhaustiveCoverageStrategy(hasBinds: false)
        #expect(strategy.generate(profile: profile, budget: 5) == nil)
        #expect(strategy.estimatedRows(profile: profile, budget: 5) == nil)
    }

    @Test("Returns nil when binds are present even if space fits")
    func rejectsBinds() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(in: 0 ... 2)
        )))
        let strategy = ExhaustiveCoverageStrategy(hasBinds: true)
        #expect(strategy.generate(profile: profile, budget: 100) == nil)
        #expect(strategy.estimatedRows(profile: profile, budget: 100) == nil)
    }

    @Test("Estimated rows matches totalSpace")
    func estimatedRowsMatchesTotalSpace() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false])
        )))
        let strategy = ExhaustiveCoverageStrategy(hasBinds: false)
        #expect(strategy.estimatedRows(profile: profile, budget: 10) == 8)
    }
}

// MARK: - T-Way Strategy

@Suite("TWayCoverageStrategy")
struct TWayCoverageStrategyTests {
    @Test("Generates pairwise covering for multi-parameter profile")
    func pairwiseCovering() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2)
        )))
        let strategy = TWayCoverageStrategy()
        let covering = strategy.generate(profile: profile, budget: 100)
        #expect(covering != nil)
        #expect(covering!.strength >= 2)
    }

    @Test("Returns nil for single-parameter profile")
    func rejectsSingleParameter() throws {
        let profile = try #require(analyzeFinite(Gen.choose(in: 0 ... 4)))
        let strategy = TWayCoverageStrategy()
        #expect(strategy.generate(profile: profile, budget: 100) == nil)
        #expect(strategy.estimatedRows(profile: profile, budget: 100) == nil)
    }

    @Test("Respects maxStrength cap")
    func respectsMaxStrength() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false]),
            Gen.choose(from: [true, false])
        )))
        let capped = TWayCoverageStrategy(maxStrength: 2)
        let uncapped = TWayCoverageStrategy(maxStrength: 4)

        let cappedResult = capped.generate(profile: profile, budget: 100)
        let uncappedResult = uncapped.generate(profile: profile, budget: 100)
        #expect(cappedResult != nil)
        #expect(uncappedResult != nil)
        #expect(cappedResult!.strength <= 2)
        #expect(uncappedResult!.strength >= cappedResult!.strength)
    }

    @Test("Returns nil when even t=2 exceeds budget")
    func exceedsBudget() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(in: 0 ... 200),
            Gen.choose(in: 0 ... 200)
        )))
        // 201 x 201 seed = 40401 rows, exceeds budget of 50
        let strategy = TWayCoverageStrategy()
        #expect(strategy.generate(profile: profile, budget: 50) == nil)
    }
}

// MARK: - Single-Parameter Strategy

@Suite("SingleParameterCoverageStrategy")
struct SingleParameterCoverageStrategyTests {
    @Test("Generates strength-1 covering for single parameter")
    func singleParameter() throws {
        let profile = try #require(analyzeFinite(Gen.choose(in: 0 ... 4)))
        let strategy = SingleParameterCoverageStrategy()
        let covering = strategy.generate(profile: profile, budget: 10)
        #expect(covering != nil)
        #expect(covering?.strength == 1)
        #expect(covering?.rows.count == 5)
    }

    @Test("Returns nil for multi-parameter profile")
    func rejectsMultiParameter() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2)
        )))
        let strategy = SingleParameterCoverageStrategy()
        #expect(strategy.generate(profile: profile, budget: 100) == nil)
        #expect(strategy.estimatedRows(profile: profile, budget: 100) == nil)
    }
}

// MARK: - Boundary Strategy

@Suite("BoundaryValueCoverageStrategy")
struct BoundaryValueCoverageStrategyTests {
    @Test("Generates covering for boundary profile")
    func generatesCovering() {
        guard case let .boundary(profile) = ChoiceTreeAnalysis.analyze(Gen.zip(
            Gen.choose(in: 0 ... 10000),
            Gen.choose(in: 0 ... 10000)
        )) else {
            Issue.record("Expected boundary analysis result")
            return
        }
        let strategy = BoundaryValueCoverageStrategy()
        let covering = strategy.generate(profile: profile, budget: 100)
        #expect(covering != nil)
        #expect(covering!.strength >= 1)
    }

    @Test("Generates trivial covering for single-parameter boundary")
    func singleParameterBoundary() {
        guard case let .boundary(profile) = ChoiceTreeAnalysis.analyze(
            Gen.choose(in: 0 ... 10000)
        ) else {
            Issue.record("Expected boundary analysis result")
            return
        }
        let strategy = BoundaryValueCoverageStrategy()
        let covering = strategy.generate(profile: profile, budget: 100)
        #expect(covering != nil)
        #expect(covering?.strength == 1)
    }
}

// MARK: - Strategy Chain Ordering

@Suite("CoverageStrategy chain")
struct CoverageStrategyChainTests {
    @Test("Exhaustive wins over t-way when space fits")
    func exhaustiveWinsWhenFits() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(from: [true, false]),
            Gen.choose(in: 0 ... 2)
        )))
        let strategies: [any CoverageStrategy] = [
            ExhaustiveCoverageStrategy(hasBinds: false),
            TWayCoverageStrategy(),
            SingleParameterCoverageStrategy(),
        ]

        var winnerPhase: CoveragePhase?
        for strategy in strategies {
            if strategy.generate(profile: profile, budget: 10) != nil {
                winnerPhase = strategy.phase
                break
            }
        }
        #expect(winnerPhase == .exhaustive)
    }

    @Test("T-way wins when space exceeds budget")
    func tWayWinsWhenExhaustiveTooLarge() throws {
        let profile = try #require(analyzeFinite(Gen.zip(
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2),
            Gen.choose(in: 0 ... 2)
        )))
        let strategies: [any CoverageStrategy] = [
            ExhaustiveCoverageStrategy(hasBinds: false),
            TWayCoverageStrategy(),
            SingleParameterCoverageStrategy(),
        ]

        var winnerName: CoverageStrategyName?
        for strategy in strategies {
            if strategy.generate(profile: profile, budget: 15) != nil {
                winnerName = strategy.name
                break
            }
        }
        #expect(winnerName == .tWay)
    }

    @Test("Single-parameter fallback wins for 1-param profile with binds")
    func singleParameterFallback() throws {
        let profile = try #require(analyzeFinite(Gen.choose(in: 0 ... 3)))
        // Exhaustive rejects due to binds; t-way rejects single param
        let strategies: [any CoverageStrategy] = [
            ExhaustiveCoverageStrategy(hasBinds: true),
            TWayCoverageStrategy(),
            SingleParameterCoverageStrategy(),
        ]

        var winnerName: CoverageStrategyName?
        for strategy in strategies {
            if strategy.generate(profile: profile, budget: 10) != nil {
                winnerName = strategy.name
                break
            }
        }
        #expect(winnerName == .singleParameter)
    }
}

// MARK: - Helpers

private func analyzeFinite(_ gen: ReflectiveGenerator<some Any>) -> FiniteDomainProfile? {
    guard case let .finite(profile) = ChoiceTreeAnalysis.analyze(gen) else { return nil }
    return profile
}
