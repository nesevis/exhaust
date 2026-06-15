// MARK: - Etna BST Workload

//
// Faithful port of etna-haskell-bst (Keles et al., 2026).
// Source: https://github.com/alpaylan/etna-haskell-bst
// Implementation and bugs from Hughes, "How to Specify It" (2019).
//
// 8 mutants (insert_1..3, delete_4..5, union_6..8), 52 tasks.

import Exhaust

// MARK: - Type

/// Haskell source:
///   data Tree k v = E | T (Tree k v) k v (Tree k v)
enum EtnaBST: Equatable, Hashable, Sendable {
    case empty
    indirect case node(EtnaBST, Int, Int, EtnaBST)
}

extension EtnaBST: CustomStringConvertible {
    var description: String {
        switch self {
            case .empty: "E"
            case let .node(left, key, value, right): "(T \(left) \(key) \(value) \(right))"
        }
    }
}

// MARK: - Correct Operations

/// Haskell source:
///   insert k v E = T E k v E
///   insert k v (T l k' v' r)
///     | k < k' = T (insert k v l) k' v' r
///     | k > k' = T l k' v' (insert k v r)
///     | otherwise = T l k' v r
func bstInsert(_ key: Int, _ value: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .node(.empty, key, value, .empty)
        case let .node(left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return .node(bstInsert(key, value, left), nodeKey, nodeValue, right)
            } else if key > nodeKey {
                return .node(left, nodeKey, nodeValue, bstInsert(key, value, right))
            } else {
                return .node(left, key, value, right)
            }
    }
}

/// Haskell source:
///   delete _ E = E
///   delete k (T l k' v' r)
///     | k < k' = T (delete k l) k' v' r
///     | k > k' = T l k' v' (delete k r)
///     | otherwise = join l r
func bstDelete(_ key: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .empty
        case let .node(left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return .node(bstDelete(key, left), nodeKey, nodeValue, right)
            } else if key > nodeKey {
                return .node(left, nodeKey, nodeValue, bstDelete(key, right))
            } else {
                return bstJoin(left, right)
            }
    }
}

/// Haskell source:
///   join E r = r
///   join l E = l
///   join (T l k v r) (T l' k' v' r') =
///     T l k v (T (join r l') k' v' r')
func bstJoin(_ left: EtnaBST, _ right: EtnaBST) -> EtnaBST {
    switch (left, right) {
        case (.empty, _): return right
        case (_, .empty): return left
        case let (.node(leftL, leftK, leftV, leftR), .node(rightL, rightK, rightV, rightR)):
            return .node(leftL, leftK, leftV, .node(bstJoin(leftR, rightL), rightK, rightV, rightR))
    }
}

/// Haskell source:
///   union E r = r
///   union l E = l
///   union (T l k v r) t =
///     T (union l (below k t)) k v (union r (above k t))
func bstUnion(_ left: EtnaBST, _ right: EtnaBST) -> EtnaBST {
    switch (left, right) {
        case (.empty, _): return right
        case (_, .empty): return left
        case let (.node(leftL, key, value, leftR), _):
            return .node(bstUnion(leftL, bstBelow(key, right)), key, value, bstUnion(leftR, bstAbove(key, right)))
    }
}

/// Haskell source:
///   below _ E = E
///   below k (T l k' v r)
///     | k <= k' = below k l
///     | otherwise = T l k' v (below k r)
func bstBelow(_ key: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty: return .empty
        case let .node(left, nodeKey, nodeValue, right):
            if key <= nodeKey {
                return bstBelow(key, left)
            } else {
                return .node(left, nodeKey, nodeValue, bstBelow(key, right))
            }
    }
}

/// Haskell source:
///   above _ E = E
///   above k (T l k' v r)
///     | k >= k' = above k r
///     | otherwise = T (above k l) k' v r
func bstAbove(_ key: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty: return .empty
        case let .node(left, nodeKey, nodeValue, right):
            if key >= nodeKey {
                return bstAbove(key, right)
            } else {
                return .node(bstAbove(key, left), nodeKey, nodeValue, right)
            }
    }
}

// MARK: - Spec Helpers

func bstFind(_ key: Int, _ tree: EtnaBST) -> Int? {
    switch tree {
        case .empty: return nil
        case let .node(left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return bstFind(key, left)
            } else if key > nodeKey {
                return bstFind(key, right)
            } else {
                return nodeValue
            }
    }
}

func bstToList(_ tree: EtnaBST) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    bstToListAccum(tree, into: &result)
    return result
}

private func bstToListAccum(_ tree: EtnaBST, into result: inout [(Int, Int)]) {
    guard case let .node(left, key, value, right) = tree else { return }
    bstToListAccum(left, into: &result)
    result.append((key, value))
    bstToListAccum(right, into: &result)
}

func bstIsBST(_ tree: EtnaBST) -> Bool {
    bstIsBSTHelper(tree, min: nil, max: nil)
}

private func bstIsBSTHelper(_ tree: EtnaBST, min: Int?, max: Int?) -> Bool {
    guard case let .node(left, key, _, right) = tree else { return true }
    if let min, key <= min { return false }
    if let max, key >= max { return false }
    return bstIsBSTHelper(left, min: min, max: key)
        && bstIsBSTHelper(right, min: key, max: max)
}

/// Haskell source:
///   (=~=) :: Tree Key Val -> Tree Key Val -> Bool
///   t1 =~= t2 = toList t1 == toList t2
func bstStructurallyEqual(_ lhs: EtnaBST, _ rhs: EtnaBST) -> Bool {
    bstListsEqual(bstToList(lhs), bstToList(rhs))
}

func bstListsEqual(_ lhs: [(Int, Int)], _ rhs: [(Int, Int)]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
}

func bstDeleteKey(_ key: Int, _ list: [(Int, Int)]) -> [(Int, Int)] {
    list.filter { $0.0 != key }
}

func bstSortedInsert(_ key: Int, _ value: Int, _ list: [(Int, Int)]) -> [(Int, Int)] {
    var result = bstDeleteKey(key, list)
    let index = result.firstIndex { $0.0 > key } ?? result.endIndex
    result.insert((key, value), at: index)
    return result
}

func bstSortedUnion(_ left: [(Int, Int)], _ right: [(Int, Int)]) -> [(Int, Int)] {
    var seen = Set<Int>()
    var result: [(Int, Int)] = []
    for entry in left where seen.insert(entry.0).inserted {
        result.append(entry)
    }
    for entry in right where seen.insert(entry.0).inserted {
        result.append(entry)
    }
    return result.sorted { $0.0 < $1.0 }
}

// MARK: - Mutants

/// Haskell source (insert_1):
///   insert k v (T l k' v' r) = T E k v E
func bstInsert_1(_ key: Int, _ value: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .node(.empty, key, value, .empty)
        case .node:
            return .node(.empty, key, value, .empty)
    }
}

/// Haskell source (insert_2):
///   insert k v (T l k' v' r)
///     | k < k' = T (insert k v l) k' v' r
///     | otherwise = T l k' v r
func bstInsert_2(_ key: Int, _ value: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .node(.empty, key, value, .empty)
        case let .node(left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return .node(bstInsert_2(key, value, left), nodeKey, nodeValue, right)
            } else {
                return .node(left, nodeKey, value, right)
            }
    }
}

/// Haskell source (insert_3):
///   insert k v (T l k' v' r)
///     | k < k' = T (insert k v l) k' v' r
///     | k > k' = T l k' v' (insert k v r)
///     | otherwise = T l k' v' r
func bstInsert_3(_ key: Int, _ value: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .node(.empty, key, value, .empty)
        case let .node(left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return .node(bstInsert_3(key, value, left), nodeKey, nodeValue, right)
            } else if key > nodeKey {
                return .node(left, nodeKey, nodeValue, bstInsert_3(key, value, right))
            } else {
                // BUG: keeps old value v' instead of new value v
                return .node(left, nodeKey, nodeValue, right)
            }
    }
}

/// Haskell source (delete_4):
///   delete k (T l k' v' r)
///     | k < k' = delete k l
///     | k > k' = delete k r
///     | otherwise = join l r
func bstDelete_4(_ key: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .empty
        case let .node(left, nodeKey, _, right):
            if key < nodeKey {
                // BUG: drops the parent node, returns only the recursive result
                return bstDelete_4(key, left)
            } else if key > nodeKey {
                // BUG: drops the parent node
                return bstDelete_4(key, right)
            } else {
                return bstJoin(left, right)
            }
    }
}

/// Haskell source (delete_5):
///   delete k (T l k' v' r)
///     | k > k' = T (delete k l) k' v' r
///     | k < k' = T l k' v' (delete k r)
///     | otherwise = join l r
func bstDelete_5(_ key: Int, _ tree: EtnaBST) -> EtnaBST {
    switch tree {
        case .empty:
            return .empty
        case let .node(left, nodeKey, nodeValue, right):
            if key > nodeKey {
                // BUG: goes left instead of right
                return .node(bstDelete_5(key, left), nodeKey, nodeValue, right)
            } else if key < nodeKey {
                // BUG: goes right instead of left
                return .node(left, nodeKey, nodeValue, bstDelete_5(key, right))
            } else {
                return bstJoin(left, right)
            }
    }
}

/// Haskell source (union_6):
///   union (T l k v r) (T l' k' v' r') =
///     T l k v (T (union r l') k' v' r')
func bstUnion_6(_ left: EtnaBST, _ right: EtnaBST) -> EtnaBST {
    switch (left, right) {
        case (.empty, _): return right
        case (_, .empty): return left
        case let (.node(leftL, leftK, leftV, leftR), .node(rightL, rightK, rightV, rightR)):
            // BUG: naive graft, no below/above splitting
            return .node(leftL, leftK, leftV, .node(bstUnion_6(leftR, rightL), rightK, rightV, rightR))
    }
}

/// Haskell source (union_7):
///   union (T l k v r) (T l' k' v' r')
///     | k == k'   = T (union l l') k v (union r r')
///     | k < k'    = T l k v (T (union r l') k' v' r')
///     | otherwise = union (T l' k' v' r') (T l k v r)
func bstUnion_7(_ left: EtnaBST, _ right: EtnaBST) -> EtnaBST {
    switch (left, right) {
        case (.empty, _): return right
        case (_, .empty): return left
        case let (.node(leftL, leftK, leftV, leftR), .node(rightL, rightK, rightV, rightR)):
            if leftK == rightK {
                return .node(bstUnion_7(leftL, rightL), leftK, leftV, bstUnion_7(leftR, rightR))
            } else if leftK < rightK {
                // BUG: naive graft for k < k' case (same as union_6)
                return .node(leftL, leftK, leftV, .node(bstUnion_7(leftR, rightL), rightK, rightV, rightR))
            } else {
                return bstUnion_7(right, left)
            }
    }
}

/// Haskell source (union_8):
///   union (T l k v r) (T l' k' v' r')
///     | k == k'   = T (union l l') k v (union r r')
///     | k < k'    = T (union l (below k l')) k v
///                          (union r (T (above k l') k' v' r'))
///     | otherwise = union (T l' k' v' r') (T l k v r)
func bstUnion_8(_ left: EtnaBST, _ right: EtnaBST) -> EtnaBST {
    switch (left, right) {
        case (.empty, _): return right
        case (_, .empty): return left
        case let (.node(leftL, leftK, leftV, leftR), .node(rightL, rightK, rightV, rightR)):
            if leftK == rightK {
                return .node(bstUnion_8(leftL, rightL), leftK, leftV, bstUnion_8(leftR, rightR))
            } else if leftK < rightK {
                // BUG: splits only l' (left subtree of right tree), not the whole right tree
                return .node(
                    bstUnion_8(leftL, bstBelow(leftK, rightL)),
                    leftK, leftV,
                    bstUnion_8(leftR, .node(bstAbove(leftK, rightL), rightK, rightV, rightR))
                )
            } else {
                return bstUnion_8(right, left)
            }
    }
}

// MARK: - Generators

let etnaBSTTreeGen = #gen(intGen, intGen)
    .array()
    .map { pairs in
        pairs.reduce(EtnaBST.empty) { tree, pair in
            bstInsert(pair.0, pair.1, tree)
        }
    }

let etnaBSTInsertInputGen = #gen(etnaBSTTreeGen, intGen, intGen)
let etnaBSTDeleteInputGen = #gen(etnaBSTTreeGen, intGen)
let etnaBSTInsertPostInputGen = #gen(etnaBSTTreeGen, intGen, intGen, intGen)
let etnaBSTDeletePostInputGen = #gen(etnaBSTTreeGen, intGen, intGen)
let etnaBSTUnionInputGen = #gen(etnaBSTTreeGen, etnaBSTTreeGen)
let etnaBSTUnionPostInputGen = #gen(etnaBSTTreeGen, etnaBSTTreeGen, intGen)
let etnaBSTInsertInsertInputGen = #gen(etnaBSTTreeGen, intGen, intGen, intGen, intGen)
let etnaBSTInsertDeleteInputGen = #gen(etnaBSTTreeGen, intGen, intGen, intGen)
let etnaBSTDeleteDeleteInputGen = #gen(etnaBSTTreeGen, intGen, intGen)
let etnaBSTInsertUnionInputGen = #gen(etnaBSTTreeGen, etnaBSTTreeGen, intGen, intGen)
let etnaBSTUnionUnionInputGen = #gen(etnaBSTTreeGen, etnaBSTTreeGen, etnaBSTTreeGen)
