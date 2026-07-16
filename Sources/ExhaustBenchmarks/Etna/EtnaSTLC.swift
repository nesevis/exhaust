// MARK: - Etna STLC Workload

//
// Faithful port of etna-haskell-stlc (Keles et al., 2026).
// Source: https://github.com/alpaylan/etna-haskell-stlc
// Simply-typed lambda calculus with DeBruijn indices and parallel reduction.
//
// 10 mutants (4 in shift, 4 in subst, 2 in substTop), 20 tasks.

import Exhaust

// MARK: - Types

/// Haskell source:
///   data Typ = TBool | TFun Typ Typ
indirect enum STLCType: Equatable, Hashable, Sendable {
    case bool
    case function(STLCType, STLCType)
}

/// Haskell source:
///   data Expr = Var Int | Bool Bool | Abs Typ Expr | App Expr Expr
indirect enum STLCExpr: Equatable, Hashable, Sendable {
    case variable(Int)
    case boolean(Bool)
    case abstraction(STLCType, STLCExpr)
    case application(STLCExpr, STLCExpr)
}

extension STLCType: CustomStringConvertible {
    var description: String {
        switch self {
            case .bool: "(TBool)"
            case let .function(param, ret): "(TFun \(param) \(ret))"
        }
    }
}

extension STLCExpr: CustomStringConvertible {
    var description: String {
        switch self {
            case let .variable(index): "(Var \(index))"
            case let .boolean(value): "(Bool \(value ? "#t" : "#f"))"
            case let .abstraction(type, body): "(Abs \(type) \(body))"
            case let .application(function, argument): "(App \(function) \(argument))"
        }
    }
}

// MARK: - Mutation Variants

enum ShiftVariant {
    case correct
    case varNone
    case varAll
    case varLeq
    case absNoIncr
}

enum SubstVariant {
    case correct
    case varAll
    case varNone
    case absNoShift
    case absNoIncr
}

enum SubstTopVariant {
    case correct
    case noShift
    case noShiftBack
}

struct STLCConfig {
    var shift: ShiftVariant = .correct
    var subst: SubstVariant = .correct
    var substTop: SubstTopVariant = .correct
}

// MARK: - Type Checking

/// Haskell source:
///   getTyp ctx (Var n) | n >= 0 && n < length ctx = return (ctx !! n) | otherwise = Nothing
///   getTyp _ (Bool _) = return TBool
///   getTyp ctx (Abs t e) = do { t' <- getTyp (t : ctx) e; return (TFun t t') }
///   getTyp ctx (App e1 e2) = do
///     TFun t11 t12 <- getTyp ctx e1; t2 <- getTyp ctx e2
///     if t11 == t2 then return t12 else Nothing
func stlcGetType(_ context: [STLCType], _ expr: STLCExpr) -> STLCType? {
    switch expr {
        case let .variable(index):
            guard index >= 0, index < context.count else { return nil }
            return context[index]
        case .boolean:
            return .bool
        case let .abstraction(paramType, body):
            guard let bodyType = stlcGetType([paramType] + context, body) else { return nil }
            return .function(paramType, bodyType)
        case let .application(function, argument):
            guard let funcType = stlcGetType(context, function),
                  case let .function(paramType, returnType) = funcType,
                  let argType = stlcGetType(context, argument),
                  paramType == argType
            else { return nil }
            return returnType
    }
}

// MARK: - Shift

//
// Haskell source (correct):
//   shift d = go 0
//     where
//       go c (Var n) | n < c = Var n | otherwise = Var (n + d)
//       go _ (Bool b) = Bool b
//       go c (Abs t e) = Abs t (go (c + 1) e)
//       go c (App e1 e2) = App (go c e1) (go c e2)

private func stlcShiftImpl(_ delta: Int, _ expr: STLCExpr, config: STLCConfig) -> STLCExpr {
    func go(_ cutoff: Int, _ expr: STLCExpr) -> STLCExpr {
        switch expr {
            case let .variable(index):
                switch config.shift {
                    case .varNone:
                        // shift_var_none: = Var n
                        return .variable(index)
                    case .varAll:
                        // shift_var_all: = Var (n + d)
                        return .variable(index + delta)
                    case .varLeq:
                        // shift_var_leq: | n <= c = Var n | otherwise = Var (n + d)
                        return .variable(index <= cutoff ? index : index + delta)
                    default:
                        return .variable(index < cutoff ? index : index + delta)
                }

            case .boolean:
                return expr

            case let .abstraction(type, body):
                switch config.shift {
                    case .absNoIncr:
                        // shift_abs_no_incr: Abs t (go c e)
                        return .abstraction(type, go(cutoff, body))
                    default:
                        return .abstraction(type, go(cutoff + 1, body))
                }

            case let .application(function, argument):
                return .application(go(cutoff, function), go(cutoff, argument))
        }
    }
    return go(0, expr)
}

// MARK: - Substitution

//
// Haskell source (correct):
//   subst n s (Var m) | m == n = s | otherwise = Var m
//   subst _ _ (Bool b) = Bool b
//   subst n s (Abs t e) = Abs t (subst (n + 1) (shift 1 s) e)
//   subst n s (App e1 e2) = App (subst n s e1) (subst n s e2)

private func stlcSubstImpl(
    _ index: Int,
    _ replacement: STLCExpr,
    _ expr: STLCExpr,
    config: STLCConfig
) -> STLCExpr {
    switch expr {
        case let .variable(varIndex):
            switch config.subst {
                case .varAll:
                    // subst_var_all: = s
                    return replacement
                case .varNone:
                    // subst_var_none: = Var m
                    return .variable(varIndex)
                default:
                    return varIndex == index ? replacement : .variable(varIndex)
            }

        case .boolean:
            return expr

        case let .abstraction(type, body):
            switch config.subst {
                case .absNoShift:
                    // subst_abs_no_shift: Abs t (subst (n + 1) s e)
                    return .abstraction(type,
                                        stlcSubstImpl(index + 1, replacement, body, config: config))
                case .absNoIncr:
                    // subst_abs_no_incr: Abs t (subst n (shift 1 s) e)
                    return .abstraction(type,
                                        stlcSubstImpl(index, stlcShiftImpl(1, replacement, config: config), body, config: config))
                default:
                    return .abstraction(type,
                                        stlcSubstImpl(index + 1, stlcShiftImpl(1, replacement, config: config), body, config: config))
            }

        case let .application(function, argument):
            return .application(
                stlcSubstImpl(index, replacement, function, config: config),
                stlcSubstImpl(index, replacement, argument, config: config)
            )
    }
}

// MARK: - Top-Level Substitution

//
// Haskell source (correct):
//   substTop s e = shift (-1) (subst 0 (shift 1 s) e)

private func stlcSubstTopImpl(
    _ replacement: STLCExpr,
    _ expr: STLCExpr,
    config: STLCConfig
) -> STLCExpr {
    switch config.substTop {
        case .noShift:
            // substTop_no_shift: substTop s e = subst 0 s e
            return stlcSubstImpl(0, replacement, expr, config: config)
        case .noShiftBack:
            // substTop_no_shift_back: substTop s e = subst 0 (shift 1 s) e
            return stlcSubstImpl(0, stlcShiftImpl(1, replacement, config: config), expr, config: config)
        case .correct:
            let shifted = stlcShiftImpl(1, replacement, config: config)
            let substituted = stlcSubstImpl(0, shifted, expr, config: config)
            return stlcShiftImpl(-1, substituted, config: config)
    }
}

// MARK: - Parallel Reduction

//
// Haskell source:
//   pstep (Abs t e) = Abs t <$> pstep e
//   pstep (App (Abs _ e1) e2) =
//     let e1' = fromMaybe e1 (pstep e1)
//         e2' = fromMaybe e2 (pstep e2)
//      in return (substTop e2' e1')
//   pstep (App e1 e2) =
//     case (pstep e1, pstep e2) of
//       (Nothing, Nothing) -> Nothing
//       (me1, me2) -> let e1' = fromMaybe e1 me1
//                         e2' = fromMaybe e2 me2
//                      in return (App e1' e2')
//   pstep _ = Nothing

func stlcPstepImpl(_ expr: STLCExpr, config: STLCConfig) -> STLCExpr? {
    switch expr {
        case let .abstraction(type, body):
            return stlcPstepImpl(body, config: config).map { .abstraction(type, $0) }

        case let .application(.abstraction(_, body), argument):
            let bodyPrime = stlcPstepImpl(body, config: config) ?? body
            let argPrime = stlcPstepImpl(argument, config: config) ?? argument
            return stlcSubstTopImpl(argPrime, bodyPrime, config: config)

        case let .application(function, argument):
            let funcStep = stlcPstepImpl(function, config: config)
            let argStep = stlcPstepImpl(argument, config: config)
            if funcStep == nil, argStep == nil { return nil }
            return .application(funcStep ?? function, argStep ?? argument)

        default:
            return nil
    }
}

// MARK: - Multi-Step

//
// Haskell source:
//   multistep 0 _ _ = Nothing
//   multistep fuel step e = case step e of
//     Nothing -> return e
//     Just e' -> multistep (fuel - 1) step e'

func stlcMultistepImpl(_ fuel: Int, _ expr: STLCExpr, config: STLCConfig) -> STLCExpr? {
    if fuel == 0 { return nil }
    guard let stepped = stlcPstepImpl(expr, config: config) else { return expr }
    return stlcMultistepImpl(fuel - 1, stepped, config: config)
}

// MARK: - Correct Operations

func stlcShift(_ delta: Int, _ expr: STLCExpr) -> STLCExpr {
    stlcShiftImpl(delta, expr, config: .init())
}

func stlcSubst(_ index: Int, _ replacement: STLCExpr, _ expr: STLCExpr) -> STLCExpr {
    stlcSubstImpl(index, replacement, expr, config: .init())
}

func stlcSubstTop(_ replacement: STLCExpr, _ expr: STLCExpr) -> STLCExpr {
    stlcSubstTopImpl(replacement, expr, config: .init())
}

func stlcPstep(_ expr: STLCExpr) -> STLCExpr? {
    stlcPstepImpl(expr, config: .init())
}

// MARK: - Mutant Configs

/// Haskell source (shift_var_none):
///   go c (Var n) = Var n
let stlcConfig_shiftVarNone = STLCConfig(shift: .varNone)

/// Haskell source (shift_var_all):
///   go c (Var n) = Var (n + d)
let stlcConfig_shiftVarAll = STLCConfig(shift: .varAll)

/// Haskell source (shift_var_leq):
///   go c (Var n) | n <= c = Var n | otherwise = Var (n + d)
let stlcConfig_shiftVarLeq = STLCConfig(shift: .varLeq)

/// Haskell source (shift_abs_no_incr):
///   go c (Abs t e) = Abs t (go c e)
let stlcConfig_shiftAbsNoIncr = STLCConfig(shift: .absNoIncr)

/// Haskell source (subst_var_all):
///   subst n s (Var m) = s
let stlcConfig_substVarAll = STLCConfig(subst: .varAll)

/// Haskell source (subst_var_none):
///   subst n s (Var m) = Var m
let stlcConfig_substVarNone = STLCConfig(subst: .varNone)

/// Haskell source (subst_abs_no_shift):
///   subst n s (Abs t e) = Abs t (subst (n + 1) s e)
let stlcConfig_substAbsNoShift = STLCConfig(subst: .absNoShift)

/// Haskell source (subst_abs_no_incr):
///   subst n s (Abs t e) = Abs t (subst n (shift 1 s) e)
let stlcConfig_substAbsNoIncr = STLCConfig(subst: .absNoIncr)

/// Haskell source (substTop_no_shift):
///   substTop s e = subst 0 s e
let stlcConfig_substTopNoShift = STLCConfig(substTop: .noShift)

/// Haskell source (substTop_no_shift_back):
///   substTop s e = subst 0 (shift 1 s) e
let stlcConfig_substTopNoShiftBack = STLCConfig(substTop: .noShiftBack)

// MARK: - Bespoke Well-Typed Generator

//
// Mirrors the Haskell bespoke generator (Strategy/Correct.hs):
//   1. Generate a random type (Arbitrary Typ)
//   2. Generate a term of that type (genExactExpr [] t)
//   3. In App, generate a random argument type (arbitrary)

/// Haskell source:
///   instance Arbitrary Typ where
///     arbitrary = sized go where
///       go 0 = return TBool
///       go n = oneof [go 0, TFun <$> go (n `div` 2) <*> go (n `div` 2)]
private func stlcTypeGen(depth: Int) -> ReflectiveGenerator<STLCType> {
    if depth <= 0 {
        return .just(.bool)
    }
    let half = depth / 2
    return .oneOf(
        .just(.bool),
        #gen(stlcTypeGen(depth: half), stlcTypeGen(depth: half))
            .map { param, ret in STLCType.function(param, ret) }
    )
}

/// Haskell source:
///   genOne _ TBool = Bool <$> arbitrary
///   genOne ctx (TFun t1 t2) = Abs t1 <$> genOne (t1 : ctx) t2
private func stlcGenOne(
    _ type: STLCType,
    context: [STLCType]
) -> ReflectiveGenerator<STLCExpr> {
    switch type {
        case .bool:
            return .oneOf(.just(.boolean(true)), .just(.boolean(false)))
        case let .function(paramType, returnType):
            return stlcGenOne(returnType, context: [paramType] + context)
                .map { body in STLCExpr.abstraction(paramType, body) }
    }
}

/// Haskell source:
///   genExactExpr ctx t = sized $ \n -> go n ctx t
///     go 0 ctx t = oneof $ genOne ctx t : genVar ctx t
///     go n ctx t = oneof ([genOne ctx t] ++ [genAbs ...] ++ [genApp ctx t] ++ genVar ctx t)
///       genApp ctx t = do { t' <- arbitrary; e1 <- go (n `div` 2) ctx (TFun t' t); e2 <- go (n `div` 2) ctx t'; return (App e1 e2) }
private func stlcTermOfType(
    _ type: STLCType,
    context: [STLCType],
    depth: Int
) -> ReflectiveGenerator<STLCExpr> {
    var generators: [ReflectiveGenerator<STLCExpr>] = []

    // genVar: variables from context matching the type
    for (index, contextType) in context.enumerated() where contextType == type {
        generators.append(.just(.variable(index)))
    }

    // genOne: base-case constructor for the type
    switch type {
        case .bool:
            generators.append(.oneOf(.just(.boolean(true)), .just(.boolean(false))))
        case let .function(paramType, returnType):
            let genOneBody = stlcTermOfType(returnType, context: [paramType] + context, depth: 0)
            generators.append(genOneBody.map { body in STLCExpr.abstraction(paramType, body) })
    }

    if depth > 0 {
        // genAbs: deeper Abs (only for function types)
        if case let .function(paramType, returnType) = type {
            let genAbsBody = stlcTermOfType(returnType, context: [paramType] + context, depth: depth - 1)
            generators.append(genAbsBody.map { body in STLCExpr.abstraction(paramType, body) })
        }

        // genApp: generate a random argument type, then function and argument
        let half = depth / 2
        generators.append(stlcTypeGen(depth: half).bind { argType in
            let funcGen = stlcTermOfType(.function(argType, type), context: context, depth: half)
            let argGen = stlcTermOfType(argType, context: context, depth: half)
            return #gen(funcGen, argGen).map { function, argument in
                STLCExpr.application(function, argument)
            }
        })
    }

    if generators.count == 1 {
        return generators[0]
    }
    let frozen = generators
    let count = frozen.count
    return #gen(.int(in: 0 ... (count - 1), scaling: .constant)).bind { index in
        frozen[index]
    }
}

/// Haskell source:
///   instance Arbitrary Expr where
///     arbitrary = do { t <- arbitrary; genExactExpr [] t }
///   -- both `arbitrary` for Typ and `genExactExpr` use `sized`
let etnaSTLCExprGen: ReflectiveGenerator<STLCExpr> =
    stlcTypeGen(depth: 3).bind { type in
        stlcTermOfType(type, context: [], depth: 3)
    }

// MARK: - Faithful Rust Port

//
// Faithful port of etna-rust-stlc (Keles et al., 2026).
// Source: https://github.com/alpaylan/etna-rust-stlc
//
// Differences from the fast generator above:
//   - Type gen uses frequency weighting: (1, TBool), (depth, TFun), capped at depth 5
//   - genOne is self-recursive (no variables at leaves)
//   - genVar is a single entry picking uniformly among candidates
//   - Expression depth capped at 10 (matching Rust's g.size().min(10))
//   - Lazy construction: sub-generators built inside .bind, only the chosen
//     branch materializes per sample (~depth nodes, not ~2^depth)
//
// These mutations require ~30K-60K samples to find reliably:
//   shift_var_leq, subst_abs_no_shift

/// Rust source:
///   fn gen_typ(g: &mut Gen, size: usize) -> Typ {
///     if size == 0 { TBool }
///     else { g.frequency(&[(1, TBool), (size, TFun(gen_typ(size/2), gen_typ(size/2)))]) }
///   }
///   impl Arbitrary for Typ { fn arbitrary(g) { gen_typ(g, g.size().min(5)) } }
private func stlcTypeGenRust(depth: Int) -> ReflectiveGenerator<STLCType> {
    if depth <= 0 {
        return .just(.bool)
    }
    let half = depth / 2
    return .oneOf(
        weighted: (1, .just(.bool)),
        (depth, #gen(stlcTypeGenRust(depth: half), stlcTypeGenRust(depth: half))
            .map { param, ret in STLCType.function(param, ret) })
    )
}

/// Rust source:
///   fn gen_exact_expr(ctx, t, g, size) {
///     if size == 0 { g.choose(&[gen_one, gen_var?]) }
///     else { g.choose(&[gen_one, gen_app, gen_abs?, gen_var?]) }
///   }
private func stlcTermOfTypeRust(
    _ type: STLCType,
    context: [STLCType],
    depth: Int
) -> ReflectiveGenerator<STLCExpr> {
    let matchingIndices = context.enumerated().compactMap { $0.element == type ? $0.offset : nil }
    let isFunctionType: (STLCType, STLCType)? = {
        if case let .function(param, ret) = type { return (param, ret) }
        return nil
    }()

    // Rust order: [genOne, genApp?, genAbs?, genVar?]
    // At depth 0: [genOne, genVar?]
    var optionCount = 1
    if depth > 0 {
        optionCount += 1 // genApp
        if isFunctionType != nil { optionCount += 1 }
    }
    if matchingIndices.isEmpty == false { optionCount += 1 }

    if optionCount == 1 {
        return stlcGenOne(type, context: context)
    }

    return #gen(.int(in: 0 ... (optionCount - 1), scaling: .constant)).bind { choice in
        var index = choice

        // genOne
        if index == 0 {
            return stlcGenOne(type, context: context)
        }
        index -= 1

        // genApp (depth > 0)
        if depth > 0 {
            if index == 0 {
                let half = depth / 2
                return stlcTypeGenRust(depth: half).bind { argType in
                    let funcGen = stlcTermOfTypeRust(.function(argType, type), context: context, depth: half)
                    let argGen = stlcTermOfTypeRust(argType, context: context, depth: half)
                    return #gen(funcGen, argGen).map { function, argument in
                        STLCExpr.application(function, argument)
                    }
                }
            }
            index -= 1

            // genAbs (function types only, depth > 0)
            if let (paramType, returnType) = isFunctionType {
                if index == 0 {
                    return stlcTermOfTypeRust(returnType, context: [paramType] + context, depth: depth - 1)
                        .map { body in STLCExpr.abstraction(paramType, body) }
                }
                index -= 1
            }
        }

        // genVar
        return #gen(.element(from: matchingIndices)).map { STLCExpr.variable($0) }
    }
}

let etnaSTLCExprGenRust: ReflectiveGenerator<STLCExpr> =
    stlcTypeGenRust(depth: 5).bind { type in
        stlcTermOfTypeRust(type, context: [], depth: 10)
    }

// MARK: - Validation

func validateEtnaSTLCGenerator() {
    do {
        let terms = try #example(etnaSTLCExprGen, count: 50)
        if terms.allSatisfy({ stlcGetType([], $0) != nil }) == false {
            fatalError("STLC generator produced ill-typed term")
        }
    } catch {
        fatalError("STLC example generation failed: \(error)")
    }
}
