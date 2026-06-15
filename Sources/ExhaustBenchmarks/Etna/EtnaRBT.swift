// MARK: - Etna RBT Workload

//
// Faithful port of etna-haskell-rbt (Keles et al., 2026).
// Source: https://github.com/alpaylan/etna-haskell-rbt
// Based on SmallCheck (Okasaki 1999) and Kent RBT delete.
//
// 15 mutants, 58 tasks.

import Exhaust

// MARK: - Types

/// Haskell source:
///   data Color = R | B
enum RBTColor: Equatable, Hashable, Sendable {
    case red
    case black
}

/// Haskell source:
///   data Tree k v = E | T Color (Tree k v) k v (Tree k v)
enum EtnaRBT: Equatable, Hashable, Sendable {
    case empty
    indirect case node(RBTColor, EtnaRBT, Int, Int, EtnaRBT)
}

/// Haskell source:
///   data Error = IE
enum RBTError: Error, Equatable, Sendable {
    case invariantError
}

extension RBTColor: CustomStringConvertible {
    var description: String {
        switch self {
            case .red: "(R)"
            case .black: "(B)"
        }
    }
}

extension EtnaRBT: CustomStringConvertible {
    var description: String {
        switch self {
            case .empty: "(E)"
            case let .node(color, left, key, value, right):
                "(T \(color) \(left) \(key) \(value) \(right))"
        }
    }
}

// MARK: - Mutation Variants

private enum BalanceVariant {
    case correct
    case swapBC
    case swapCD
}

private enum InsertVariant {
    case correct
    case insert1
    case insert2
    case insert3
    case miscolorInsert
    case noBalance1
    case noBalance2
}

private struct RBTDeleteConfig {
    enum DelVariant {
        case correct
        case delete4
        case delete5
    }

    enum BalLeftVariant {
        case correct
        case miscolor
    }

    enum BalRightVariant {
        case correct
        case miscolor
    }

    enum JoinVariant {
        case correct
        case miscolorJoin1
        case miscolorJoin2
    }

    var del: DelVariant = .correct
    var balLeft: BalLeftVariant = .correct
    var balRight: BalRightVariant = .correct
    var join: JoinVariant = .correct
    var balance: BalanceVariant = .correct
    var applyBlacken: Bool = true
}

// MARK: - Helpers

/// Haskell: blacken E = E; blacken (T _ a x vx b) = T B a x vx b
private func rbtBlacken(_ tree: EtnaRBT) -> EtnaRBT {
    switch tree {
        case .empty: return .empty
        case let .node(_, left, key, value, right):
            return .node(.black, left, key, value, right)
    }
}

/// Haskell: redden (T B a x vx b) = return $ T R a x vx b; redden _ = Left IE
private func rbtRedden(_ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    switch tree {
        case let .node(.black, left, key, value, right):
            return .success(.node(.red, left, key, value, right))
        default:
            return .failure(.invariantError)
    }
}

// MARK: - Balance

//
// Haskell source:
//   balance B (T R (T R a x vx b) y vy c) z vz d = T R (T B a x vx b) y vy (T B c z vz d)
//   balance B (T R a x vx (T R b y vy c)) z vz d = T R (T B a x vx b) y vy (T B c z vz d)
//   balance B a x vx (T R (T R b y vy c) z vz d) = T R (T B a x vx b) y vy (T B c z vz d)
//   balance B a x vx (T R b y vy (T R c z vz d)) = T R (T B a x vx b) y vy (T B c z vz d)
//   balance rb a x vx b = T rb a x vx b
//
// Mutants swap_cd and swap_bc change cases 1 and 3 respectively.

private func rbtBalanceImpl(
    _ color: RBTColor,
    _ left: EtnaRBT,
    _ key: Int,
    _ value: Int,
    _ right: EtnaRBT,
    variant: BalanceVariant = .correct
) -> EtnaRBT {
    switch (color, left, right) {
        // Case 1 (LL): balance B (T R (T R a x vx b) y vy c) z vz d
        case let (.black, .node(.red, .node(.red, a, xKey, xVal, b), yKey, yVal, c), d):
            switch variant {
                case .swapCD:
                    // swap_cd: T R (T B a x vx b) y vy (T B d z vz c)
                    return .node(.red,
                                 .node(.black, a, xKey, xVal, b),
                                 yKey, yVal,
                                 .node(.black, d, key, value, c))
                default:
                    return .node(.red,
                                 .node(.black, a, xKey, xVal, b),
                                 yKey, yVal,
                                 .node(.black, c, key, value, d))
            }

        // Case 2 (LR): balance B (T R a x vx (T R b y vy c)) z vz d
        case let (.black, .node(.red, a, xKey, xVal, .node(.red, b, yKey, yVal, c)), d):
            return .node(.red,
                         .node(.black, a, xKey, xVal, b),
                         yKey, yVal,
                         .node(.black, c, key, value, d))

        // Case 3 (RL): balance B a x vx (T R (T R b y vy c) z vz d)
        case let (.black, a, .node(.red, .node(.red, b, yKey, yVal, c), zKey, zVal, d)):
            switch variant {
                case .swapBC:
                    // swap_bc: T R (T B a x vx c) y vy (T B b z vz d)
                    return .node(.red,
                                 .node(.black, a, key, value, c),
                                 yKey, yVal,
                                 .node(.black, b, zKey, zVal, d))
                default:
                    return .node(.red,
                                 .node(.black, a, key, value, b),
                                 yKey, yVal,
                                 .node(.black, c, zKey, zVal, d))
            }

        // Case 4 (RR): balance B a x vx (T R b y vy (T R c z vz d))
        case let (.black, a, .node(.red, b, yKey, yVal, .node(.red, c, zKey, zVal, d))):
            return .node(.red,
                         .node(.black, a, key, value, b),
                         yKey, yVal,
                         .node(.black, c, zKey, zVal, d))

        default:
            return .node(color, left, key, value, right)
    }
}

// MARK: - Insert Implementation

//
// Haskell source (correct):
//   insert x vx s = blacken (ins x vx s)
//     where
//       ins x vx E = T R E x vx E
//       ins x vx (T rb a y vy b)
//         | x < y = balance rb (ins x vx a) y vy b
//         | x > y = balance rb a y vy (ins x vx b)
//         | otherwise = T rb a y vx b

private func rbtInsImpl(
    _ key: Int,
    _ value: Int,
    _ tree: EtnaRBT,
    variant: InsertVariant,
    balance: BalanceVariant,
    outerInsert: (Int, Int, EtnaRBT) -> EtnaRBT
) -> EtnaRBT {
    switch tree {
        case .empty:
            switch variant {
                case .miscolorInsert:
                    // miscolor_insert: T B E x vx E
                    return .node(.black, .empty, key, value, .empty)
                default:
                    return .node(.red, .empty, key, value, .empty)
            }

        case let .node(color, left, nodeKey, nodeValue, right):
            switch variant {
                case .insert1:
                    // insert_1: = T R E x vx E
                    return .node(.red, .empty, key, value, .empty)

                case .insert2:
                    // insert_2: | x < y = balance rb (ins x vx a) y vy b
                    //           | otherwise = T rb a y vx b
                    if key < nodeKey {
                        return rbtBalanceImpl(color,
                                              rbtInsImpl(key, value, left, variant: variant, balance: balance, outerInsert: outerInsert),
                                              nodeKey, nodeValue, right, variant: balance)
                    } else {
                        return .node(color, left, nodeKey, value, right)
                    }

                case .insert3:
                    // insert_3: | otherwise = T rb a y vy b  (keeps old value)
                    if key < nodeKey {
                        return rbtBalanceImpl(color,
                                              rbtInsImpl(key, value, left, variant: variant, balance: balance, outerInsert: outerInsert),
                                              nodeKey, nodeValue, right, variant: balance)
                    } else if key > nodeKey {
                        return rbtBalanceImpl(color, left, nodeKey, nodeValue,
                                              rbtInsImpl(key, value, right, variant: variant, balance: balance, outerInsert: outerInsert),
                                              variant: balance)
                    } else {
                        return .node(color, left, nodeKey, nodeValue, right)
                    }

                case .noBalance1:
                    // no_balance_insert_1: | x < y = T rb (ins x vx a) y vy b
                    if key < nodeKey {
                        return .node(color,
                                     rbtInsImpl(key, value, left, variant: variant, balance: balance, outerInsert: outerInsert),
                                     nodeKey, nodeValue, right)
                    } else if key > nodeKey {
                        return rbtBalanceImpl(color, left, nodeKey, nodeValue,
                                              rbtInsImpl(key, value, right, variant: variant, balance: balance, outerInsert: outerInsert),
                                              variant: balance)
                    } else {
                        return .node(color, left, key, value, right)
                    }

                case .noBalance2:
                    // no_balance_insert_2: | x > y = T rb a y vy (insert x vx b)
                    if key < nodeKey {
                        return rbtBalanceImpl(color,
                                              rbtInsImpl(key, value, left, variant: variant, balance: balance, outerInsert: outerInsert),
                                              nodeKey, nodeValue, right, variant: balance)
                    } else if key > nodeKey {
                        return .node(color, left, nodeKey, nodeValue, outerInsert(key, value, right))
                    } else {
                        return .node(color, left, key, value, right)
                    }

                default:
                    if key < nodeKey {
                        return rbtBalanceImpl(color,
                                              rbtInsImpl(key, value, left, variant: variant, balance: balance, outerInsert: outerInsert),
                                              nodeKey, nodeValue, right, variant: balance)
                    } else if key > nodeKey {
                        return rbtBalanceImpl(color, left, nodeKey, nodeValue,
                                              rbtInsImpl(key, value, right, variant: variant, balance: balance, outerInsert: outerInsert),
                                              variant: balance)
                    } else {
                        return .node(color, left, key, value, right)
                    }
            }
    }
}

private func rbtInsertImpl(
    _ key: Int,
    _ value: Int,
    _ tree: EtnaRBT,
    variant: InsertVariant = .correct,
    balance: BalanceVariant = .correct
) -> EtnaRBT {
    func outerInsert(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
        rbtInsertImpl(key, value, tree, variant: variant, balance: balance)
    }
    return rbtBlacken(rbtInsImpl(key, value, tree, variant: variant, balance: balance, outerInsert: outerInsert))
}

// MARK: - Delete Implementation

//
// Haskell source (correct):
//   delete x t = blacken <$> del t
//     where
//       del E = return E
//       del (T _ a y vy b)
//         | x < y = delLeft a y vy b
//         | x > y = delRight a y vy b
//         | otherwise = join a b

private func rbtDeleteImpl(
    _ key: Int,
    _ tree: EtnaRBT,
    config: RBTDeleteConfig = .init()
) -> Result<EtnaRBT, RBTError> {
    let result = rbtDelImpl(key, tree, config: config)
    return config.applyBlacken ? result.map(rbtBlacken) : result
}

private func rbtDelImpl(
    _ key: Int,
    _ tree: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch tree {
        case .empty:
            return .success(.empty)

        case let .node(_, left, nodeKey, nodeValue, right):
            switch config.del {
                case .delete4:
                    // delete_4: | x < y = del a; | x > y = del b
                    if key < nodeKey {
                        return rbtDelImpl(key, left, config: config)
                    } else if key > nodeKey {
                        return rbtDelImpl(key, right, config: config)
                    } else {
                        return rbtJoinImpl(left, right, config: config)
                    }

                case .delete5:
                    // delete_5: | x > y = delLeft; | x < y = delRight (swapped)
                    if key > nodeKey {
                        return rbtDelLeftImpl(key, left, nodeKey, nodeValue, right, config: config)
                    } else if key < nodeKey {
                        return rbtDelRightImpl(key, left, nodeKey, nodeValue, right, config: config)
                    } else {
                        return rbtJoinImpl(left, right, config: config)
                    }

                case .correct:
                    if key < nodeKey {
                        return rbtDelLeftImpl(key, left, nodeKey, nodeValue, right, config: config)
                    } else if key > nodeKey {
                        return rbtDelRightImpl(key, left, nodeKey, nodeValue, right, config: config)
                    } else {
                        return rbtJoinImpl(left, right, config: config)
                    }
            }
    }
}

/// Haskell:
///   delLeft a@(T B _ _ _ _) y vy b = do { a' <- del a; balLeft a' y vy b }
///   delLeft a y vy b = do { a' <- del a; return $ T R a' y vy b }
private func rbtDelLeftImpl(
    _ key: Int,
    _ left: EtnaRBT,
    _ nodeKey: Int,
    _ nodeValue: Int,
    _ right: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch left {
        case .node(.black, _, _, _, _):
            return rbtDelImpl(key, left, config: config).flatMap { leftResult in
                rbtBalLeftImpl(leftResult, nodeKey, nodeValue, right, config: config)
            }
        default:
            return rbtDelImpl(key, left, config: config).map { leftResult in
                .node(.red, leftResult, nodeKey, nodeValue, right)
            }
    }
}

/// Haskell:
///   delRight a y vy b@(T B _ _ _ _) = balRight a y vy =<< del b
///   delRight a y vy b = T R a y vy <$> del b
private func rbtDelRightImpl(
    _ key: Int,
    _ left: EtnaRBT,
    _ nodeKey: Int,
    _ nodeValue: Int,
    _ right: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch right {
        case .node(.black, _, _, _, _):
            return rbtDelImpl(key, right, config: config).flatMap { rightResult in
                rbtBalRightImpl(left, nodeKey, nodeValue, rightResult, config: config)
            }
        default:
            return rbtDelImpl(key, right, config: config).map { rightResult in
                .node(.red, left, nodeKey, nodeValue, rightResult)
            }
    }
}

/// Haskell:
///   balLeft (T R a x vx b) y vy c = return $ T R (T B a x vx b) y vy c
///   balLeft bl x vx (T B a y vy b) = return $ balance B bl x vx (T R a y vy b)
///   balLeft bl x vx (T R (T B a y vy b) z vz c) = do
///     c' <- redden c; return $ T R (T B bl x vx a) y vy (balance B b z vz c')
///   balLeft _ _ _ _ = Left IE
private func rbtBalLeftImpl(
    _ left: EtnaRBT,
    _ key: Int,
    _ value: Int,
    _ right: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch (left, right) {
        case let (.node(.red, a, xKey, xVal, b), c):
            return .success(.node(.red, .node(.black, a, xKey, xVal, b), key, value, c))

        case let (bl, .node(.black, a, yKey, yVal, b)):
            return .success(rbtBalanceImpl(.black, bl, key, value, .node(.red, a, yKey, yVal, b), variant: config.balance))

        case let (bl, .node(.red, .node(.black, a, yKey, yVal, b), zKey, zVal, c)):
            switch config.balLeft {
                case .correct:
                    return rbtRedden(c).map { cPrime in
                        .node(.red,
                              .node(.black, bl, key, value, a),
                              yKey, yVal,
                              rbtBalanceImpl(.black, b, zKey, zVal, cPrime, variant: config.balance))
                    }
                case .miscolor:
                    // miscolor_balLeft: skips redden c, uses c directly
                    return .success(.node(.red,
                                          .node(.black, bl, key, value, a),
                                          yKey, yVal,
                                          rbtBalanceImpl(.black, b, zKey, zVal, c, variant: config.balance)))
            }

        default:
            return .failure(.invariantError)
    }
}

/// Haskell:
///   balRight a x vx (T R b y vy c) = return $ T R a x vx (T B b y vy c)
///   balRight (T B a x vx b) y vy bl = return $ balance B (T R a x vx b) y vy bl
///   balRight (T R a x vx (T B b y vy c)) z vz bl = do
///     a' <- redden a; return $ T R (balance B a' x vx b) y vy (T B c z vz bl)
///   balRight _ _ _ _ = Left IE
private func rbtBalRightImpl(
    _ left: EtnaRBT,
    _ key: Int,
    _ value: Int,
    _ right: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch (left, right) {
        case let (a, .node(.red, b, yKey, yVal, c)):
            return .success(.node(.red, a, key, value, .node(.black, b, yKey, yVal, c)))

        case let (.node(.black, a, xKey, xVal, b), bl):
            return .success(rbtBalanceImpl(.black, .node(.red, a, xKey, xVal, b), key, value, bl, variant: config.balance))

        case let (.node(.red, a, xKey, xVal, .node(.black, b, yKey, yVal, c)), bl):
            switch config.balRight {
                case .correct:
                    return rbtRedden(a).map { aPrime in
                        .node(.red,
                              rbtBalanceImpl(.black, aPrime, xKey, xVal, b, variant: config.balance),
                              yKey, yVal,
                              .node(.black, c, key, value, bl))
                    }
                case .miscolor:
                    // miscolor_balRight: skips redden a, uses a directly
                    return .success(.node(.red,
                                          rbtBalanceImpl(.black, a, xKey, xVal, b, variant: config.balance),
                                          yKey, yVal,
                                          .node(.black, c, key, value, bl)))
            }

        default:
            return .failure(.invariantError)
    }
}

/// Haskell:
///   join E a = return a
///   join a E = return a
///   join (T R a x vx b) (T R c y vy d) = do
///     t' <- join b c
///     case t' of
///       T R b' z vz c' -> return $ T R (T R a x vx b') z vz (T R c' y vy d)
///       bc -> return $ T R a x vx (T R bc y vy d)
///   join (T B a x vx b) (T B c y vy d) = do
///     t' <- join b c
///     case t' of
///       T R b' z vz c' -> return $ T R (T B a x vx b') z vz (T B c' y vy d)
///       bc -> balLeft a x vx (T B bc y vy d)
///   join a (T R b x vx c) = do { t' <- join a b; return $ T R t' x vx c }
///   join (T R a x vx b) c = T R a x vx <$> join b c
private func rbtJoinImpl(
    _ left: EtnaRBT,
    _ right: EtnaRBT,
    config: RBTDeleteConfig
) -> Result<EtnaRBT, RBTError> {
    switch (left, right) {
        case (.empty, _):
            return .success(right)

        case (_, .empty):
            return .success(left)

        // Both Red
        case let (.node(.red, a, xKey, xVal, b), .node(.red, c, yKey, yVal, d)):
            return rbtJoinImpl(b, c, config: config).map { tPrime in
                switch tPrime {
                    case let .node(.red, bPrime, zKey, zVal, cPrime):
                        switch config.join {
                            case .miscolorJoin1:
                                // miscolor_join_1: inner nodes B instead of R
                                .node(.red,
                                      .node(.black, a, xKey, xVal, bPrime),
                                      zKey, zVal,
                                      .node(.black, cPrime, yKey, yVal, d))
                            default:
                                .node(.red,
                                      .node(.red, a, xKey, xVal, bPrime),
                                      zKey, zVal,
                                      .node(.red, cPrime, yKey, yVal, d))
                        }
                    default:
                        .node(.red, a, xKey, xVal, .node(.red, tPrime, yKey, yVal, d))
                }
            }

        // Both Black
        case let (.node(.black, a, xKey, xVal, b), .node(.black, c, yKey, yVal, d)):
            return rbtJoinImpl(b, c, config: config).flatMap { tPrime in
                switch tPrime {
                    case let .node(.red, bPrime, zKey, zVal, cPrime):
                        switch config.join {
                            case .miscolorJoin2:
                                // miscolor_join_2: inner nodes R instead of B
                                return .success(.node(.red,
                                                      .node(.red, a, xKey, xVal, bPrime),
                                                      zKey, zVal,
                                                      .node(.red, cPrime, yKey, yVal, d)))
                            default:
                                return .success(.node(.red,
                                                      .node(.black, a, xKey, xVal, bPrime),
                                                      zKey, zVal,
                                                      .node(.black, cPrime, yKey, yVal, d)))
                        }
                    default:
                        return rbtBalLeftImpl(a, xKey, xVal, .node(.black, tPrime, yKey, yVal, d), config: config)
                }
            }

        // Left Black, Right Red
        case let (.node(.black, _, _, _, _), .node(.red, b, xKey, xVal, c)):
            return rbtJoinImpl(left, b, config: config).map { tPrime in
                .node(.red, tPrime, xKey, xVal, c)
            }

        // Left Red, Right Black
        case let (.node(.red, a, xKey, xVal, b), .node(.black, _, _, _, _)):
            return rbtJoinImpl(b, right, config: config).map { tPrime in
                .node(.red, a, xKey, xVal, tPrime)
            }
    }
}

// MARK: - Correct Operations

/// Haskell source:
///   insert x vx s = blacken (ins x vx s)
func rbtInsert(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree)
}

/// Haskell source:
///   delete x t = blacken <$> del t
func rbtDelete(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree)
}

// MARK: - Insert Mutants

/// Haskell source (insert_1):
///   ins x vx (T rb a y vy b) = T R E x vx E
func rbtInsert_1(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .insert1)
}

/// Haskell source (insert_2):
///   ins x vx (T rb a y vy b)
///     | x < y = balance rb (ins x vx a) y vy b
///     | otherwise = T rb a y vx b
func rbtInsert_2(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .insert2)
}

/// Haskell source (insert_3):
///   ins x vx (T rb a y vy b)
///     | x < y = balance rb (ins x vx a) y vy b
///     | x > y = balance rb a y vy (ins x vx b)
///     | otherwise = T rb a y vy b
func rbtInsert_3(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .insert3)
}

/// Haskell source (miscolor_insert):
///   ins x vx E = T B E x vx E
func rbtInsert_miscolorInsert(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .miscolorInsert)
}

/// Haskell source (no_balance_insert_1):
///   ins x vx (T rb a y vy b)
///     | x < y = T rb (ins x vx a) y vy b
///     | x > y = balance rb a y vy (ins x vx b)
///     | otherwise = T rb a y vx b
func rbtInsert_noBalance1(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .noBalance1)
}

/// Haskell source (no_balance_insert_2):
///   ins x vx (T rb a y vy b)
///     | x < y = balance rb (ins x vx a) y vy b
///     | x > y = T rb a y vy (insert x vx b)
///     | otherwise = T rb a y vx b
func rbtInsert_noBalance2(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, variant: .noBalance2)
}

// MARK: - Balance Mutants (Insert Side)

/// Haskell source (swap_bc): case 3 of balance swaps b and c.
///   balance B a x vx (T R (T R b y vy c) z vz d) = T R (T B a x vx c) y vy (T B b z vz d)
func rbtInsert_swapBC(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, balance: .swapBC)
}

/// Haskell source (swap_cd): case 1 of balance swaps c and d.
///   balance B (T R (T R a x vx b) y vy c) z vz d = T R (T B a x vx b) y vy (T B d z vz c)
func rbtInsert_swapCD(_ key: Int, _ value: Int, _ tree: EtnaRBT) -> EtnaRBT {
    rbtInsertImpl(key, value, tree, balance: .swapCD)
}

// MARK: - Delete Mutants

/// Haskell source (delete_4):
///   del (T _ a y vy b)
///     | x < y = del a
///     | x > y = del b
///     | otherwise = join a b
func rbtDelete_4(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(del: .delete4))
}

/// Haskell source (delete_5):
///   del (T _ a y vy b)
///     | x > y = delLeft a y vy b
///     | x < y = delRight a y vy b
///     | otherwise = join a b
func rbtDelete_5(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(del: .delete5))
}

/// Haskell source (miscolor_delete):
///   delete x t = del t  (no blacken)
func rbtDelete_miscolorDelete(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(applyBlacken: false))
}

/// Haskell source (miscolor_balLeft): balLeft case 3 skips ``redden c``, uses ``c`` directly.
func rbtDelete_miscolorBalLeft(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(balLeft: .miscolor))
}

/// Haskell source (miscolor_balRight): balRight case 3 skips ``redden a``, uses ``a`` directly.
func rbtDelete_miscolorBalRight(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(balRight: .miscolor))
}

/// Haskell source (miscolor_join_1): join RR case colors inner nodes B instead of R.
///   T R b' z vz c' -> return $ T R (T B a x vx b') z vz (T B c' y vy d)
func rbtDelete_miscolorJoin1(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(join: .miscolorJoin1))
}

/// Haskell source (miscolor_join_2): join BB case colors inner nodes R instead of B.
///   T R b' z vz c' -> return $ T R (T R a x vx b') z vz (T R c' y vy d)
func rbtDelete_miscolorJoin2(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(join: .miscolorJoin2))
}

// MARK: - Balance Mutants (Delete Side)

/// Haskell source (swap_bc): balance case 3 swaps b and c. Affects delete's balLeft/balRight.
func rbtDelete_swapBC(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(balance: .swapBC))
}

/// Haskell source (swap_cd): balance case 1 swaps c and d. Affects delete's balLeft/balRight.
func rbtDelete_swapCD(_ key: Int, _ tree: EtnaRBT) -> Result<EtnaRBT, RBTError> {
    rbtDeleteImpl(key, tree, config: .init(balance: .swapCD))
}

// MARK: - Spec Helpers

/// Haskell source:
///   find _ E = Nothing
///   find x (T _ l y vy r)
///     | x < y = find x l
///     | x > y = find x r
///     | otherwise = Just vy
func rbtFind(_ key: Int, _ tree: EtnaRBT) -> Int? {
    switch tree {
        case .empty:
            return nil
        case let .node(_, left, nodeKey, nodeValue, right):
            if key < nodeKey {
                return rbtFind(key, left)
            } else if key > nodeKey {
                return rbtFind(key, right)
            } else {
                return nodeValue
            }
    }
}

/// Haskell source:
///   toList E = []
///   toList (T _ l k v r) = toList l ++ [(k, v)] ++ toList r
func rbtToList(_ tree: EtnaRBT) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    rbtToListAccum(tree, into: &result)
    return result
}

private func rbtToListAccum(_ tree: EtnaRBT, into result: inout [(Int, Int)]) {
    guard case let .node(_, left, key, value, right) = tree else { return }
    rbtToListAccum(left, into: &result)
    result.append((key, value))
    rbtToListAccum(right, into: &result)
}

/// Haskell: (=~=) for Result comparison via toList.
func rbtResultsEqual(
    _ lhs: Result<EtnaRBT, RBTError>,
    _ rhs: Result<EtnaRBT, RBTError>
) -> Bool {
    switch (lhs, rhs) {
        case let (.success(left), .success(right)):
            return bstListsEqual(rbtToList(left), rbtToList(right))
        default:
            return false
    }
}

// MARK: - Validity

extension EtnaRBT {
    /// Haskell: isBST — strict ordering, no duplicate keys.
    var isValidBST: Bool {
        isValidBSTHelper(min: nil, max: nil)
    }

    private func isValidBSTHelper(min: Int?, max: Int?) -> Bool {
        switch self {
            case .empty:
                return true
            case let .node(_, left, key, _, right):
                if let min, key <= min { return false }
                if let max, key >= max { return false }
                return left.isValidBSTHelper(min: min, max: key)
                    && right.isValidBSTHelper(min: key, max: max)
        }
    }

    /// Haskell: noRedRed — no red node has a red parent.
    var hasNoRedRedViolation: Bool {
        switch self {
            case .empty:
                return true
            case let .node(.black, left, _, _, right):
                return left.hasNoRedRedViolation && right.hasNoRedRedViolation
            case let .node(.red, left, _, _, right):
                return left.isBlackRoot && right.isBlackRoot
                    && left.hasNoRedRedViolation && right.hasNoRedRedViolation
        }
    }

    /// Haskell: consistentBlackHeight — every path has the same number of black nodes.
    var blackHeight: Int? {
        switch self {
            case .empty:
                return 1
            case let .node(color, left, _, _, right):
                guard let leftHeight = left.blackHeight,
                      let rightHeight = right.blackHeight,
                      leftHeight == rightHeight
                else {
                    return nil
                }
                return leftHeight + (color == .black ? 1 : 0)
        }
    }

    var isBlackRoot: Bool {
        switch self {
            case .empty: true
            case .node(.black, _, _, _, _): true
            case .node(.red, _, _, _, _): false
        }
    }

    /// Haskell: isRBT t = isBST t && consistentBlackHeight t && noRedRed t && blackRoot t
    var isValidRBT: Bool {
        isValidBST && hasNoRedRedViolation && blackHeight != nil && isBlackRoot
    }
}

// MARK: - Generators

let etnaRBTTreeGen = #gen(intGen, intGen)
    .array()
    .map { pairs in
        pairs.reduce(EtnaRBT.empty) { tree, pair in
            rbtInsert(pair.0, pair.1, tree)
        }
    }

let etnaRBTInsertInputGen = #gen(etnaRBTTreeGen, intGen, intGen)
let etnaRBTDeleteInputGen = #gen(etnaRBTTreeGen, intGen)
let etnaRBTInsertPostInputGen = #gen(etnaRBTTreeGen, intGen, intGen, intGen)
let etnaRBTDeletePostInputGen = #gen(etnaRBTTreeGen, intGen, intGen)
let etnaRBTInsertInsertInputGen = #gen(etnaRBTTreeGen, intGen, intGen, intGen, intGen)
let etnaRBTInsertDeleteInputGen = #gen(etnaRBTTreeGen, intGen, intGen, intGen)

// MARK: - Validation

func validateEtnaRBTGenerator() {
    do {
        let trees = try #example(etnaRBTTreeGen, count: 50)
        if trees.allSatisfy(\.isValidRBT) == false {
            fatalError("RBT generator produced invalid tree")
        }
    } catch {
        fatalError("RBT example generation failed: \(error)")
    }
}

func logRBTFeederGenerator() {
    let feederGen = #gen(.int(in: -100 ... 100), .int(in: -100 ... 100))
        .array(length: 1 ... 100, scaling: .constant)

    guard let arrays = try? #example(feederGen, count: 100) else { return }
    for (index, array) in arrays.enumerated() {
        let keys = array.map(\.0)
        let uniqueKeys = Set(keys)
        print("[\(index)] len=\(array.count) unique=\(uniqueKeys.count) keys=\(keys)")
    }
}
