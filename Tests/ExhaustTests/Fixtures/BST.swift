//
//  BST.swift
//  ExhaustTests
//

@testable import Exhaust

enum BST: Equatable, Hashable, CustomStringConvertible {
    case leaf
    indirect case node(left: BST, value: UInt, right: BST)

    static func arbitrary(maxDepth: Int = 5, valueRange: ClosedRange<UInt> = 0 ... 9) -> ReflectiveGenerator<BST> {
        bstGenerator(maxDepth: maxDepth, valueRange: valueRange)
    }

    private static func bstGenerator(maxDepth: Int, valueRange: ClosedRange<UInt>) -> ReflectiveGenerator<BST> {
        if maxDepth <= 0 {
            return .just(.leaf)
        }
        let nodeBranch = #gen(bstGenerator(maxDepth: maxDepth - 1, valueRange: valueRange), .uint(in: valueRange), bstGenerator(maxDepth: maxDepth - 1, valueRange: valueRange)).map { left, value, right in
            BST.node(left: left, value: value, right: right)
        }
        return .oneOf(weighted: (1, .just(.leaf)), (3, nodeBranch))
    }

    static func arbitraryRecursive(valueRange: ClosedRange<UInt> = 0 ... 9) -> ReflectiveGenerator<BST> {
        .recursive(base: .leaf) { recurse, remaining in
            let nodeBranch = #gen(recurse(), .uint(in: valueRange), recurse()).map { left, value, right in
                BST.node(left: left, value: value, right: right)
            }
            return .oneOf(weighted: (1, .just(.leaf)), (Int(remaining), nodeBranch))
        }
    }

    func isValidBST() -> Bool {
        isValidBST(min: nil, max: nil)
    }

    private func isValidBST(min: UInt?, max: UInt?) -> Bool {
        switch self {
        case .leaf:
            return true
        case let .node(left, value, right):
            if let min, value <= min { return false }
            if let max, value >= max { return false }
            return left.isValidBST(min: min, max: value) &&
                right.isValidBST(min: value, max: max)
        }
    }

    func isValidAVL() -> Bool {
        isValidBST() && isBalanced()
    }

    private func isBalanced() -> Bool {
        switch self {
        case .leaf:
            return true
        case let .node(left, _, right):
            let diff = abs(left.height - right.height)
            return diff <= 1 && left.isBalanced() && right.isBalanced()
        }
    }

    var nodeCount: Int {
        switch self {
        case .leaf: 0
        case let .node(left, _, right):
            1 + left.nodeCount + right.nodeCount
        }
    }

    var height: Int {
        switch self {
        case .leaf: 0
        case let .node(left, _, right):
            1 + Swift.max(left.height, right.height)
        }
    }

    var description: String {
        switch self {
        case .leaf: "."
        case let .node(left, value, right): "(\(left) \(value) \(right))"
        }
    }
}
