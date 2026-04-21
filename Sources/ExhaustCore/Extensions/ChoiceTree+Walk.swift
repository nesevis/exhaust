//
//  ChoiceTree+Walk.swift
//  Exhaust
//

// MARK: - Fingerprint

/// A path-based address for locating a specific node in a ``ChoiceTree``.
///
/// Each step in the path is a child index at the corresponding depth.
/// For example, `[1, 0]` means "second child of root, then first child of that node".
package struct Fingerprint: Hashable, Sendable {
    /// The sequence of child indices that form the path from the root to a node.
    public private(set) var steps: [Int]

    /// The empty fingerprint representing the root of a tree.
    public static let root = Fingerprint(steps: [])

    /// Returns a new fingerprint with `childIndex` appended as the next step.
    public func appending(_ childIndex: Int) -> Fingerprint {
        var copy = self
        copy.steps.append(childIndex)
        return copy
    }

    /// Returns `true` when `self` is a strict ancestor of `other` (that is, `other.steps` starts with `self.steps` and is longer).
    public func isAncestor(of other: Fingerprint) -> Bool {
        steps.count < other.steps.count && other.steps.starts(with: steps)
    }
}

// MARK: - Children & replacement

package extension ChoiceTree {
    /// The immediate children of this node in traversal order.
    var children: [ChoiceTree] {
        switch self {
        case .choice, .just, .getSize:
            []
        case let .group(elements, _):
            elements
        case let .bind(_, inner, bound):
            [inner, bound]
        case let .sequence(_, elements, _):
            elements
        case let .branch(_, _, _, _, choice):
            [choice]
        case let .resize(_, choices):
            choices
        case let .selected(child):
            [child]
        }
    }

    /// Returns a copy of this node with the child at `index` replaced by `newChild`.
    func replacingChild(at index: Int, with newChild: ChoiceTree) -> ChoiceTree {
        switch self {
        case .choice, .just, .getSize:
            preconditionFailure("Leaf nodes have no children to replace")
        case let .group(elements, _):
            var copy = elements
            copy[index] = newChild
            return .group(copy)
        case let .bind(fingerprint, inner, bound):
            precondition(index < 2, "bind has exactly two children")
            return index == 0
                ? .bind(fingerprint: fingerprint, inner: newChild, bound: bound)
                : .bind(fingerprint: fingerprint, inner: inner, bound: newChild)
        case let .sequence(length, elements, metadata):
            var copy = elements
            copy[index] = newChild
            return .sequence(length: length, elements: copy, metadata)
        case let .branch(fingerprint, weight, id, branchIDs, _):
            precondition(index == 0, "branch has exactly one child")
            return .branch(fingerprint: fingerprint, weight: weight, id: id, branchIDs: branchIDs, choice: newChild)
        case let .resize(newSize, choices):
            var copy = choices
            copy[index] = newChild
            return .resize(newSize: newSize, choices: copy)
        case .selected:
            precondition(index == 0, "selected has exactly one child")
            return .selected(newChild)
        }
    }
}

// MARK: - ChoiceTreeWalker

/// A depth-first iterator that yields `(Fingerprint, ChoiceTree)` pairs for every node in a tree.
package struct ChoiceTreeWalker: IteratorProtocol, Sequence {
    /// A single item produced by ``ChoiceTreeWalker``, pairing a node with its path from the root.
    public struct Element {
        /// The path from the root to this node.
        public let fingerprint: Fingerprint
        /// The choice tree node at this position.
        public let node: ChoiceTree
    }

    private var stack: [(Fingerprint, ChoiceTree)]

    /// Creates a walker starting from the root of the given tree.
    public init(_ tree: ChoiceTree) {
        stack = [(.root, tree)]
    }

    public mutating func next() -> Element? {
        guard let (fingerprint, node) = stack.popLast() else {
            return nil
        }
        let children = node.children
        // Push in reverse so the first child is yielded first
        for i in stride(from: children.count - 1, through: 0, by: -1) {
            stack.append((fingerprint.appending(i), children[i]))
        }
        return Element(fingerprint: fingerprint, node: node)
    }
}

// MARK: - Subscript

package extension ChoiceTree {
    /// Access a node at the given fingerprint for reading or writing.
    ///
    /// The getter walks down the tree following the fingerprint's steps.
    /// The setter rebuilds the spine from root to target via ``replacingChild(at:with:)``.
    subscript(fingerprint: Fingerprint) -> ChoiceTree {
        get {
            var current = self
            for step in fingerprint.steps {
                current = current.children[step]
            }
            return current
        }
        set {
            if fingerprint.steps.isEmpty {
                self = newValue
                return
            }
            // Rebuild the spine from the deepest ancestor back up to root
            var current = newValue
            var ancestors: [(node: ChoiceTree, childIndex: Int)] = []
            var node = self
            for step in fingerprint.steps {
                ancestors.append((node: node, childIndex: step))
                node = node.children[step]
            }
            for ancestor in ancestors.reversed() {
                current = ancestor.node.replacingChild(at: ancestor.childIndex, with: current)
            }
            self = current
        }
    }

    /// Creates a ``ChoiceTreeWalker`` for depth-first traversal.
    func walk() -> ChoiceTreeWalker {
        ChoiceTreeWalker(self)
    }
}
