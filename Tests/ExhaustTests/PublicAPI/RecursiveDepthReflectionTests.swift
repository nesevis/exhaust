//
//  RecursiveDepthReflectionTests.swift
//  Exhaust
//

import Exhaust
import ExhaustCore
import Testing

@Suite("Reflection beyond a recursive generator's depth range")
struct RecursiveDepthReflectionTests {
    @Test("A target deeper than depthRange reports a reflection error")
    func targetDeeperThanDepthRangeThrows() {
        let error = #expect(throws: ReflectionError.self) {
            _ = try Interpreters.reflect(Self.treeGenerator.gen, with: Self.deepTree)
        }
        let isZipComponentFailure = switch error {
            case .couldNotReflectOnZipElement?: true
            default: false
        }
        #expect(isZipComponentFailure, "Expected a zip component failure, got \(String(describing: error))")
    }

    @Test("A target within depthRange still reflects")
    func targetWithinDepthRangeReflects() throws {
        let reflected = try Interpreters.reflect(Self.treeGenerator.gen, with: Self.shallowTree)
        #expect(reflected != nil)
    }

    @Test("Reflecting a too-deep target through #exhaust returns the value instead of trapping")
    func tooDeepTargetThroughExhaustDoesNotTrap() {
        var output: Tree?
        withKnownIssue("Reflection reports the depth mismatch as a recorded issue") {
            output = #exhaust(
                Self.treeGenerator,
                reflecting: Self.deepTree,
                .suppress(.issueReporting)
            ) { _ in
                false
            }
        }
        #expect(output == Self.deepTree)
    }

    // MARK: - Fixtures

    indirect enum Tree: Equatable, Sendable {
        case leaf
        case node(Tree, Int, Tree)
    }

    static let treeGenerator: ReflectiveGenerator<Tree> = .recursive(
        baseValue: .leaf,
        depthRange: 0 ... 2
    ) { recurse, _ in
        .oneOf(
            .just(.leaf),
            #gen(recurse(), .int(in: 0 ... 9), recurse()) { Tree.node($0, $1, $2) }
        )
    }

    /// Depth 4, two layers beyond the generator's upper bound.
    static let deepTree = Tree.node(
        .node(.node(.node(.leaf, 1, .leaf), 2, .leaf), 3, .leaf),
        4,
        .leaf
    )

    static let shallowTree = Tree.node(.leaf, 4, .leaf)
}
