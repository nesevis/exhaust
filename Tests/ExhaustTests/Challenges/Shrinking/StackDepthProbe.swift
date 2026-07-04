//
//  StackDepthProbe.swift
//  Exhaust
//
//  Probes for bind-bound materialization at extreme depths.
//

import Exhaust
import ExhaustTestSupport
import Foundation
import Testing

@Suite("Bind-Bound Materialization Probe", .tags(.challenge))
struct BindBoundMaterializationProbe {
    indirect enum SimpleExp: Equatable {
        case leaf(Int)
        case add(SimpleExp, SimpleExp)
    }

    static func fullExpAtDepth(_ depth: Int) -> ReflectiveGenerator<SimpleExp> {
        let leafGen = #gen(.int(in: 0 ... 10))
            .mapped(
                forward: { SimpleExp.leaf($0) },
                backward: {
                    if case let .leaf(n) = $0 { return n }
                    return 0
                }
            )

        guard depth > 0 else {
            return leafGen
        }

        let child = #gen(.int(in: 0 ... depth - 1))
            .bind { childDepth in
                Self.fullExpAtDepth(childDepth)
            }

        func binOp() -> ReflectiveGenerator<SimpleExp> {
            #gen(child, child)
                .mapped(
                    forward: { lhs, rhs in SimpleExp.add(lhs, rhs) },
                    backward: {
                        if case let .add(lhs, rhs) = $0 { return (lhs, rhs) }
                        return (.leaf(0), .leaf(0))
                    }
                )
        }

        return #gen(.oneOf(weighted:
            (3, leafGen),
            (100, binOp()), (100, binOp()), (100, binOp()),
            (100, binOp()), (100, binOp()), (100, binOp()),
            (100, binOp())))
    }

    /// Smoke test, debug-mode limitation, not a product bug: ReflectiveOperation is a huge switch in
    /// most interpreters and debug builds allocate all cases in each frame, so depth-100 replay
    /// overflows the stack. Release builds handle it. Disabled rather than withKnownIssue because a
    /// stack overflow kills the test process instead of recording an issue.
    @Test("Depth 100 with coverage — overflows the debug-mode stack in coverage replay", .disabled("Debug-only stack overflow (fat ReflectiveOperation switch frames); passes in release"))
    func depth100WithCoverage() {
        let gen = #gen(.int(in: 0 ... 100))
            .bind { depth in Self.fullExpAtDepth(depth) }
        // Completion is the assertion: the property always passes, so reaching this line means no overflow.
        let result = #exhaust(gen, .suppress(.issueReporting), .budget(.custom(coverage: 200, sampling: 1))) { _ in true }
        #expect(result == nil, "Property always passes, so no counterexample can exist")
    }
}
