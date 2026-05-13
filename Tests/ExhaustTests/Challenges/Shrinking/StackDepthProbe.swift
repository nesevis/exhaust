//
//  StackDepthProbe.swift
//  Exhaust
//
//  Probes for bind-bound materialization at extreme depths.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Bind-Bound Materialization Probe")
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

    @Test("Depth 100 with coverage — hangs in coverage replay", .disabled())
    func depth100WithCoverage() {
        let gen = #gen(.int(in: 0 ... 100))
            .bind { depth in Self.fullExpAtDepth(depth) }
        let result = #exhaust(gen, .suppress(.issueReporting), .budget(.custom(coverage: 200, sampling: 1))) { _ in true }
        print("Depth 100: \(String(describing: result))")
    }
}
