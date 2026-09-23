import Dispatch
import Exhaust
import ExhaustCore
import Testing
@testable import ExhaustGenerators

@Suite("Derivation tradeoff correctness")
struct DerivationTradeoffTests {
    @Test("Seed mapping is independent of cold builders and size visitation order")
    func coldAndWarmOrder() throws {
        let first = try makeTradeoffGenerator()
        let second = try makeTradeoffGenerator()
        let forward = try (1 ... 100).map { try tradeoffSamples(first, size: UInt64($0)) }
        let backward = try (1 ... 100).reversed().map { try tradeoffSamples(second, size: UInt64($0)) }
        #expect(forward == Array(backward.reversed()))
    }

    @Test("Shared generators preserve seeds under parallel interpretation")
    func concurrentInterpretation() throws {
        let generator = try makeTradeoffGenerator()
        let results = SendableBox<[Int: Result<[TradeoffTree], Error>]>([:])
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let result = Result { try tradeoffSamples(generator, size: 100) }
            results.withValue { $0[index] = result }
        }
        let expected = try tradeoffSamples(generator, size: 100)
        for index in 0 ..< 8 {
            let result = try #require(results.value[index])
            #expect(try result.get() == expected)
        }
    }
}

// MARK: - Test helpers

/// Uses independent builders so global public-factory caches cannot hide cold-path differences.
private func makeTradeoffGenerator() throws -> ReflectiveGenerator<TradeoffTree> {
    let plan = try GeneratorDerivationPlan(for: TradeoffTree.self, overrides: [:])
    return try BudgetedGeneratorDerivation(plan: plan).root(
        for: TradeoffTree.self,
        recursion: .drawn(ceiling: 5, scaling: .linear),
        maximumNodes: 200
    )
}

/// Checks the size-independent node ceiling as well as both replay paths for every generated value.
private func tradeoffSamples(_ generator: ReflectiveGenerator<TradeoffTree>, size: UInt64) throws -> [TradeoffTree] {
    var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: size)
    var result: [TradeoffTree] = []
    for _ in 0 ..< 4 {
        let (value, choices) = try #require(try interpreter.next())
        #expect(value.nodes <= 200)
        #expect(try Interpreters.replay(generator.gen, using: choices) == value)
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: value))
        #expect(try Interpreters.replay(generator.gen, using: reflected) == value)
        result.append(value)
    }
    return result
}

@Exhaustable
private indirect enum TradeoffTree: Equatable, Sendable {
    case leaf(Int)
    case branch([TradeoffTree])
    case pair(TradeoffTree, TradeoffTree)

    var nodes: Int {
        switch self {
            case .leaf:
                2
            case let .branch(children):
                2 + children.reduce(0) { $0 + $1.nodes }
            case let .pair(first, second):
                1 + first.nodes + second.nodes
        }
    }
}
