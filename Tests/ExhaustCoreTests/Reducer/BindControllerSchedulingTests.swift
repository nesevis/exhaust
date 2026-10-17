import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bind controller scheduling")
struct BindControllerSchedulingTests {
    @Test("Controllers are eligible before the first payload sweep", arguments: [8, 2048])
    func controllersBeforePayload(count: Int) throws {
        let graph = GraphFixture(Self.boundTree(count: count)).graph
        let candidates = CandidateSourceBuilder.buildMinimizationCandidates(graph: graph, deferBindInner: false)
        let first = try #require(candidates.first)
        guard case let .minimize(.valueLeaves(scope)) = first.operation else {
            Issue.record("Expected ordinary controller search first")
            return
        }
        #expect(scope.leaves.count == 1)
        #expect(scope.leaves[0].mayReshapeOnAcceptance)
        #expect(first.priority.valueBenefit >= count)
        #expect(candidates.contains { candidate in
            if case let .minimize(.valueLeaves(scope)) = candidate.operation {
                return scope.leaves.count == count
            }
            return false
        })
    }

    @Test("Payload scopes separate independent leaves and sibling bind regions")
    func separatesSiblingRegions() {
        let tree = ChoiceTree.group([
            .uint64(9, in: 0 ... 10),
            Self.boundTree(count: 8, fingerprint: 1),
            Self.boundTree(count: 12, fingerprint: 2),
        ])
        let graph = GraphFixture(tree).graph
        let scopes = MinimizationQuery.build(graph: graph).compactMap { scope -> ValueMinimizationScope? in
            guard case let .valueLeaves(values) = scope,
                  values.leaves.allSatisfy({ $0.mayReshapeOnAcceptance == false })
            else {
                return nil
            }
            return values
        }
        #expect(scopes.map { $0.leaves.count } == [1, 8, 12])
    }

    @Test("A nested payload makes every upstream controller eligible")
    func nestedControllers() {
        let tree = ChoiceTree.bind(
            fingerprint: 1, inner: .uint64(4, in: 1 ... 10),
            bound: Self.boundTree(count: 2048, fingerprint: 2)
        )
        let graph = GraphFixture(tree).graph
        let scopes = MinimizationQuery.build(graph: graph).compactMap { scope -> ValueMinimizationScope? in
            guard case let .valueLeaves(values) = scope,
                  values.leaves.contains(where: { $0.mayReshapeOnAcceptance })
            else {
                return nil
            }
            return values
        }
        #expect(scopes.count == 2)
        #expect(Set(scopes.flatMap { $0.leaves.map { $0.bindDepth } }).count == 2)
    }

    @Test("A controller shortens the counterexample before payload value search")
    func acceptedControllerRunsFirst() throws {
        let generator = Gen.choose(in: UInt64(1) ... 2048)._bound(
            forward: { count in Gen.arrayOf(Gen.choose(in: UInt64(0) ... 1), within: count ... count) },
            backward: { UInt64($0.count) }
        )
        let value = [UInt64](repeating: 1, count: 2048)
        let tree = try #require(try Interpreters.reflect(generator, with: value))
        var machine = ReductionMachine(
            gen: generator, initialTree: tree, initialOutput: value,
            config: .init(maxStalls: 1, enabledEncoders: [.valueSearch]),
            collectStats: true, property: { $0.count < 24 || $0.contains(1) == false }
        )
        let originalLength = machine.sequence.count
        var accepted = false
        for _ in 0 ..< 64 {
            guard let transition = machine.next() else {
                break
            }
            if case .dispatched(.encoderStarted(.valueSearch)) = transition,
               let session = machine.dispatchLoop.activeSession,
               case let .minimize(.valueLeaves(scope)) = session.transformation.operation
            {
                #expect(scope.leaves.count == 1)
                #expect(scope.leaves[0].mayReshapeOnAcceptance)
            }
            if case .decoded(.valueSearch, true) = transition {
                accepted = true
                break
            }
        }
        #expect(accepted)
        #expect(machine.sequence.count < originalLength)
        let output = try #require(machine.output as? [UInt64])
        #expect(output.count >= 24 && output.contains(1))

        // The shared query must also preserve failures in the scoped runner.
        let result = ScopedReductionRunner.reduce(
            generator: generator, tree: tree, output: value,
            configuration: .init(maxStalls: 1, enabledEncoders: [.valueSearch]),
            collectStats: true, property: { $0.count < 24 || $0.contains(1) == false }
        )
        let reduced = try #require(result.outcome.counterexample).1
        #expect(reduced.count < value.count)
        #expect(reduced.count >= 24 && reduced.contains(1))
    }

    private static func boundTree(count: Int, fingerprint: UInt64 = 0) -> ChoiceTree {
        .bind(
            fingerprint: fingerprint, inner: .uint64(10, in: 1 ... 10),
            bound: .sequence(
                elements: Array(repeating: .uint64(1, in: 0 ... 1), count: count),
                metadata: .init(validRange: UInt64(count) ... UInt64(count), isRangeExplicit: true)
            )
        )
    }
}
