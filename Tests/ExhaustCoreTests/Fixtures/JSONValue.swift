//
//  JSONValue.swift
//  ExhaustTests
//

import ExhaustCore

/// A simplified JSON-like recursive data type for testing `Gen.recursive`.
///
/// Exercises recursion through a collection (`.array`) — a shape distinct from
/// BST's binary recursion. Leaves are `.null` and `.int`.
enum JSONValue: Equatable, Hashable, CustomStringConvertible {
    case null
    case int(UInt)
    indirect case array([JSONValue])

    private static let valueRange: ClosedRange<UInt> = 0 ... 99

    static func arbitraryRecursive(maxDepth: UInt64 = 5) -> ReflectiveGenerator<JSONValue> {
        Gen.recursive(base: .null, maxDepth: maxDepth) { recurse, remaining in
            let intLeaf = Gen.choose(in: valueRange)._map { JSONValue.int($0) }
            let arrayBranch = Gen.arrayOf(recurse(), within: 0 ... 3, scaling: .constant)
                ._map { JSONValue.array($0) }

            return Gen.pick(choices: [
                (weight: 2, generator: Gen.just(.null)),
                (weight: 2, generator: intLeaf),
                (weight: Int(remaining), generator: arrayBranch),
            ])
        }
    }

    var depth: Int {
        switch self {
        case .null, .int: 0
        case let .array(elements):
            1 + (elements.map(\.depth).max() ?? 0)
        }
    }

    var nodeCount: Int {
        switch self {
        case .null, .int: 1
        case let .array(elements):
            1 + elements.map(\.nodeCount).reduce(0, +)
        }
    }

    var description: String {
        switch self {
        case .null: "null"
        case let .int(n): "\(n)"
        case let .array(elements):
            "[\(elements.map(\.description).joined(separator: ", "))]"
        }
    }
}
