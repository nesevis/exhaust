import ExhaustCore

// MARK: - Shared BST model

//
// Local copy of ExhaustTestSupport's BST fixture. The benchmark executable stays independent of
// ExhaustTestSupport so it never links the Testing framework; keep the generator weights and
// validity predicates in sync with the fixture when comparing against test-suite numbers.

enum BenchmarkBST: Equatable, Hashable, CustomStringConvertible {
    case leaf
    indirect case node(left: BenchmarkBST, value: UInt, right: BenchmarkBST)

    static func arbitrary(maxDepth: Int = 5, valueRange: ClosedRange<UInt> = 0 ... 9) -> Generator<BenchmarkBST> {
        bstGenerator(maxDepth: maxDepth, valueRange: valueRange)
    }

    private static func bstGenerator(maxDepth: Int, valueRange: ClosedRange<UInt>) -> Generator<BenchmarkBST> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        let nodeBranch = Gen.zip(bstGenerator(maxDepth: maxDepth - 1, valueRange: valueRange), Gen.choose(in: valueRange), bstGenerator(maxDepth: maxDepth - 1, valueRange: valueRange)).map { left, value, right in
            BenchmarkBST.node(left: left, value: value, right: right)
        }
        return Gen.pick(choices: [(1, Gen.just(.leaf)), (3, nodeBranch)])
    }

    static func arbitraryRecursive(maxDepth: UInt64 = 5, valueRange: ClosedRange<UInt> = 0 ... 9) -> Generator<BenchmarkBST> {
        Gen.recursive(baseValue: .leaf, depthRange: 0 ... Int(maxDepth)) { recurse, remaining in
            let nodeBranch = Gen.zip(recurse(), Gen.choose(in: valueRange), recurse()).map { left, value, right in
                BenchmarkBST.node(left: left, value: value, right: right)
            }
            return Gen.pick(choices: [(1, Gen.just(.leaf)), (Int(remaining), nodeBranch)])
        }
    }

    /// The paper's BST generator: follows the type definition with uniform choice weights (leaf 1 : node 1), depth 5, values 0...9.
    static func uniform(maxDepth: Int) -> Generator<BenchmarkBST> {
        if maxDepth <= 0 {
            return Gen.just(.leaf)
        }
        let nodeBranch = Gen.zip(
            uniform(maxDepth: maxDepth - 1),
            Gen.choose(in: 0 ... 9 as ClosedRange<UInt>),
            uniform(maxDepth: maxDepth - 1)
        ).map { left, value, right in
            BenchmarkBST.node(left: left, value: value, right: right)
        }
        return Gen.pick(choices: [(1, Gen.just(.leaf)), (1, nodeBranch)])
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
