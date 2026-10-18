import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bind controller scheduling")
struct BindControllerSchedulingTests {
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
