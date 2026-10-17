import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Bind composition scheduling")
struct BindCompositionSchedulingTests {
    enum Shape: CaseIterable, Sendable {
        case single, linear, branching, repeatedSite, branchingTail

        var isFullyComposable: Bool {
            switch self {
                case .single, .linear:
                    true
                case .branching, .repeatedSite, .branchingTail:
                    false
            }
        }

        var tree: ChoiceTree {
            let leaf = ChoiceTree.uint64(5, in: 0 ... 10)
            switch self {
                case .single:
                    return Self.bind(1, leaf)
                case .linear:
                    return Self.bind(1, Self.bind(2, Self.bind(3, leaf)))
                case .branching:
                    return Self.bind(1, .group([Self.bind(2, leaf), Self.bind(3, leaf)]))
                case .repeatedSite:
                    return Self.bind(1, Self.bind(2, Self.bind(1, leaf)))
                case .branchingTail:
                    return Self.bind(1, Self.bind(2, .group([Self.bind(3, leaf), Self.bind(4, leaf)])))
            }
        }

        private static func bind(_ fingerprint: UInt64, _ bound: ChoiceTree) -> ChoiceTree {
            .bind(fingerprint: fingerprint, inner: .uint64(5, in: 0 ... 10), bound: bound)
        }
    }

    @Test(
        "Incomplete compositions wait after progress but remain eligible on a stall",
        arguments: Shape.allCases, [false, true]
    )
    func dispatchAfterProgress(shape: Shape, accepted: Bool) throws {
        let fixture = GraphFixture(shape.tree)
        let root = try #require(fixture.graph.liveNodeIDs.first { nodeID in
            if case .bind = fixture.graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        let scope = try #require(MinimizationQuery.build(graph: fixture.graph).compactMap { scope -> BoundValueScope? in
            guard case let .boundValue(bound) = scope, bound.bindNodeID == root else {
                return nil
            }
            return bound
        }.first)
        #expect(fixture.graph.canComposeAllNestedBinds(under: root) == shape.isFullyComposable)

        let decision = ChoiceGraphScheduler.evaluateDispatch(
            transformation: GraphTransformation(
                operation: .minimize(.boundValue(scope)),
                priority: DispatchPriority(structuralBenefit: 0, valueBenefit: 0, reductionMagnitude: 0, estimatedCost: 1)
            ),
            graph: fixture.graph,
            sequence: fixture.sequence,
            gate: BoundValueGate(baseBudget: 15),
            scopeCache: CandidateRejectionCache(),
            graphIsStripped: false,
            anyAccepted: accepted
        )
        if accepted, shape.isFullyComposable == false {
            #expect(decision == .skip)
        } else {
            #expect(decision == .classifyBind(bindNodeID: root, fingerprint: 1))
        }
    }

    @Test("Terminal pruning rejects losing prefixes only for complete compositions", arguments: Shape.allCases)
    func terminalPruning(shape: Shape) throws {
        let fixture = GraphFixture(shape.tree)
        let bindNodeID = try #require(fixture.graph.liveNodeIDs.first { nodeID in
            if case .bind = fixture.graph.nodes[nodeID].kind {
                return true
            }
            return false
        })
        guard case let .bind(metadata) = fixture.graph.nodes[bindNodeID].kind else {
            Issue.record("Expected a bind at the root")
            return
        }
        let boundChildID = fixture.graph.nodes[bindNodeID].children[metadata.boundChildIndex]
        let boundRange = try #require(fixture.graph.nodes[boundChildID].positionRange)
        let lifted = LiftedBind(
            sequence: fixture.sequence,
            tree: shape.tree,
            graph: fixture.graph,
            bindNodeID: bindNodeID,
            boundRange: boundRange,
            isControllerTopology: false
        )
        #expect(BoundValueTerminalOrder.rejectsTerminal(lifted, incumbent: fixture.sequence) == false)
        let controllerIndex = try #require(fixture.sequence.indices.first { fixture.sequence[$0].value != nil })
        var incumbent = fixture.sequence
        incumbent[controllerIndex] = .value(.init(choice: ChoiceValue(UInt64(0), tag: .uint64), validRange: 0 ... 10))
        #expect(BoundValueTerminalOrder.rejectsTerminal(lifted, incumbent: incumbent) == shape.isFullyComposable)
    }
}
