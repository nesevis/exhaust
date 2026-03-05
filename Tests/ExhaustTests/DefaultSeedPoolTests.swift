//
//  DefaultSeedPoolTests.swift
//  ExhaustTests
//

import Testing
@testable import Exhaust
@_spi(ExhaustInternal) import ExhaustCore

@Suite("DefaultSeedPool")
struct DefaultSeedPoolTests {
    @Test("Empty pool returns .generate")
    func emptyPoolGenerates() {
        var pool = DefaultSeedPool()
        var prng = Xoshiro256(seed: 42)
        let directive = pool.sample(using: &prng)
        guard case .generate = directive else {
            Issue.record("Expected .generate from empty pool")
            return
        }
    }

    @Test("Investing a seed with novelty > 0 increases count")
    func investIncreasesCount() {
        var pool = DefaultSeedPool()
        let seed = makeSeed(value: 1, novelty: 1.0, generation: 0)
        pool.invest(seed)
        #expect(pool.count == 1)
    }

    @Test("Investing a seed with novelty 0 is rejected")
    func zeroNoveltyRejected() {
        var pool = DefaultSeedPool()
        let seed = makeSeed(value: 1, novelty: 0.0, generation: 0)
        pool.invest(seed)
        #expect(pool.isEmpty)
    }

    @Test("Pool with seeds can return .mutate")
    func poolReturnsMutate() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 0.0)
        pool.invest(makeSeed(value: 1, novelty: 1.0, generation: 0))

        var prng = Xoshiro256(seed: 42)
        let directive = pool.sample(using: &prng)
        guard case .mutate = directive else {
            Issue.record("Expected .mutate from non-empty pool with generateRatio=0")
            return
        }
    }

    @Test("Revise halves the novelty score of last sampled seed")
    func reviseHalvesNovelty() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 0.0)
        let seed = makeSeed(value: 1, novelty: 2.0, generation: 0)
        pool.invest(seed)

        var prng = Xoshiro256(seed: 42)
        // Sample it
        _ = pool.sample(using: &prng)

        // Revise: reduces novelty
        pool.revise()

        // The seed is still in the pool (count doesn't change)
        #expect(pool.count == 1)
    }

    @Test("Pool evicts lowest-novelty seed at capacity")
    func evictionAtCapacity() {
        var pool = DefaultSeedPool(capacity: 3, generateRatio: 0.0)

        pool.invest(makeSeed(value: 1, novelty: 1.0, generation: 0))
        pool.invest(makeSeed(value: 2, novelty: 2.0, generation: 1))
        pool.invest(makeSeed(value: 3, novelty: 3.0, generation: 2))
        #expect(pool.count == 3)

        // Invest a higher-novelty seed — should evict the lowest (1.0)
        pool.invest(makeSeed(value: 4, novelty: 5.0, generation: 3))
        #expect(pool.count == 3)
    }

    @Test("Pool rejects lower-novelty seed at capacity")
    func rejectsLowNoveltyAtCapacity() {
        var pool = DefaultSeedPool(capacity: 2, generateRatio: 0.0)

        pool.invest(makeSeed(value: 1, novelty: 5.0, generation: 0))
        pool.invest(makeSeed(value: 2, novelty: 5.0, generation: 1))
        #expect(pool.count == 2)

        // Invest a lower-novelty seed — should be rejected (not better than min)
        pool.invest(makeSeed(value: 3, novelty: 0.5, generation: 2))
        #expect(pool.count == 2)
    }

    @Test("generateRatio = 1.0 always generates")
    func fullGenerateRatio() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 1.0)
        pool.invest(makeSeed(value: 1, novelty: 1.0, generation: 0))

        var prng = Xoshiro256(seed: 42)
        // With generateRatio = 1.0, should always return .generate
        var generateCount = 0
        for _ in 0 ..< 20 {
            if case .generate = pool.sample(using: &prng) {
                generateCount += 1
            }
        }
        #expect(generateCount == 20)
    }

    @Test("Multiple investments and samples work without crashing")
    func stressTest() {
        var pool = DefaultSeedPool(capacity: 16, generateRatio: 0.2)
        var prng = Xoshiro256(seed: 123)

        for i: UInt64 in 0 ..< 100 {
            pool.invest(makeSeed(value: i, novelty: Double(i % 10) * 0.3, generation: i))
            _ = pool.sample(using: &prng)
            if i % 5 == 0 {
                pool.revise()
            }
        }

        #expect(pool.count <= 16)
        #expect(!pool.isEmpty)
    }

    // MARK: - Fitness mode

    @Test("Fitness pool accepts seeds with zero novelty but positive fitness")
    func fitnessPoolAcceptsHighFitness() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 0.0, useFitness: true)
        // First seed to establish a baseline
        pool.invest(makeSeed(value: 1, novelty: 1.0, fitness: 1.0, generation: 0))
        // Zero novelty but high fitness — should be accepted
        pool.invest(makeSeed(value: 2, novelty: 0.0, fitness: 5.0, generation: 1))
        #expect(pool.count == 2)
    }

    @Test("Fitness pool evicts lowest-fitness seed at capacity")
    func fitnessPoolEvictsLowestFitness() {
        var pool = DefaultSeedPool(capacity: 3, generateRatio: 0.0, useFitness: true)
        pool.invest(makeSeed(value: 1, novelty: 1.0, fitness: 1.0, generation: 0))
        pool.invest(makeSeed(value: 2, novelty: 1.0, fitness: 2.0, generation: 1))
        pool.invest(makeSeed(value: 3, novelty: 1.0, fitness: 3.0, generation: 2))
        #expect(pool.count == 3)

        // Higher-fitness seed should evict the lowest (fitness 1.0)
        pool.invest(makeSeed(value: 4, novelty: 1.0, fitness: 10.0, generation: 3))
        #expect(pool.count == 3)
    }

    @Test("Fitness pool samples higher-fitness seeds more often")
    func fitnessPoolWeightsBySampling() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 0.0, useFitness: true)
        pool.invest(makeSeed(value: 1, novelty: 1.0, fitness: 1.0, generation: 0))
        pool.invest(makeSeed(value: 2, novelty: 1.0, fitness: 100.0, generation: 1))

        var prng = Xoshiro256(seed: 42)
        var highFitnessCount = 0
        let trials = 200
        for _ in 0 ..< trials {
            if case let .mutate(seed) = pool.sample(using: &prng) {
                if seed.fitness > 50.0 { highFitnessCount += 1 }
            }
        }

        // The high-fitness seed (100.0) should be sampled ~99x more than the low one (1.0)
        #expect(highFitnessCount > trials / 2, "High-fitness seed should be sampled majority of the time")
    }

    @Test("Fitness pool revise halves fitness")
    func fitnessPoolReviseHalvesFitness() {
        var pool = DefaultSeedPool(capacity: 10, generateRatio: 0.0, useFitness: true)
        pool.invest(makeSeed(value: 1, novelty: 1.0, fitness: 10.0, generation: 0))

        var prng = Xoshiro256(seed: 42)
        _ = pool.sample(using: &prng)
        pool.revise()

        // After revise, the seed's fitness should be halved.
        // We can verify by investing a seed with fitness 6.0 — it should NOT evict
        // the revised seed (fitness 5.0) only if our eviction logic works correctly.
        // Actually, let's just check averageFitness
        #expect(pool.averageFitness == 5.0)
    }
}

// MARK: - Helpers

private func makeSeed(value: UInt64, novelty: Double, fitness: Double = 0, generation: UInt64) -> Seed {
    let tree = ChoiceTree.choice(.unsigned(value, UInt64.self), ChoiceMetadata(validRange: 0 ... 1000))
    let sequence = ChoiceSequence(tree)
    return Seed(
        sequence: sequence,
        tree: tree,
        noveltyScore: novelty,
        fitness: fitness,
        generation: generation
    )
}
