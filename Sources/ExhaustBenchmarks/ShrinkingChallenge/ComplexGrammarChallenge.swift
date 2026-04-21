// MARK: - Complex Grammar Benchmark

//
// A larger recursive expression grammar than CalculatorChallenge, intended as a stress test for the graph reducer at the workload size where partial rebuilds were designed to pay off (100–500 node candidates during reduction).
//
// Grammar: Lit | Add | Sub | Mul | Div | If | Call (variadic args)
// Property: trees with at least N operators must not contain a literal Div by zero. The artificial size floor is what keeps the counterexamples large enough to exercise the early shrink cycles where the rebuild tax should hurt.

import Exhaust

// MARK: - Type

indirect enum ComplexExpr: Equatable, CustomStringConvertible {
    case lit(Int)
    case add(ComplexExpr, ComplexExpr)
    case sub(ComplexExpr, ComplexExpr)
    case mul(ComplexExpr, ComplexExpr)
    case div(ComplexExpr, ComplexExpr)
    case ifThen(ComplexExpr, ComplexExpr, ComplexExpr)
    case call([ComplexExpr])

    var description: String {
        switch self {
        case let .lit(value):
            "\(value)"
        case let .add(lhs, rhs):
            "(\(lhs)+\(rhs))"
        case let .sub(lhs, rhs):
            "(\(lhs)-\(rhs))"
        case let .mul(lhs, rhs):
            "(\(lhs)*\(rhs))"
        case let .div(lhs, rhs):
            "(\(lhs)/\(rhs))"
        case let .ifThen(condition, thenBranch, elseBranch):
            "if(\(condition),\(thenBranch),\(elseBranch))"
        case let .call(args):
            "f(\(args.map(\.description).joined(separator: ",")))"
        }
    }
}

// MARK: - Property

private let complexGrammarMinimumOperators = 30

let complexGrammarProperty: @Sendable (ComplexExpr) -> Bool = { expr in
    if operatorCount(expr) < complexGrammarMinimumOperators {
        return true
    }
    return containsLiteralDivByZero(expr) == false
}

// MARK: - Generator

func complexGrammarGen(depth: UInt64) -> ReflectiveGenerator<ComplexExpr> {
    let leaf = #gen(.int(in: -10 ... 10, scaling: .constant))
        .mapped(
            forward: { value in ComplexExpr.lit(value) },
            backward: complexBackwardLit
        )

    return #gen(.recursive(base: leaf, depthRange: 0 ... depth) { recurse, _ in
        let add = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in ComplexExpr.add(lhs, rhs) },
                backward: complexBackwardBinary
            )
        let sub = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in ComplexExpr.sub(lhs, rhs) },
                backward: complexBackwardBinary
            )
        let mul = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in ComplexExpr.mul(lhs, rhs) },
                backward: complexBackwardBinary
            )
        let div = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in ComplexExpr.div(lhs, rhs) },
                backward: complexBackwardBinary
            )
        let ifThen = #gen(recurse(), recurse(), recurse())
            .mapped(
                forward: { condition, thenBranch, elseBranch in
                    ComplexExpr.ifThen(condition, thenBranch, elseBranch)
                },
                backward: complexBackwardTernary
            )
        let call = recurse().array(length: 0 ... 3, scaling: .constant)
            .mapped(
                forward: { args in ComplexExpr.call(args) },
                backward: complexBackwardCall
            )

        return .oneOf(weighted:
            (1, leaf),
            (3, add),
            (3, sub),
            (3, mul),
            (3, div),
            (2, ifThen),
            (2, call))
    })
}

// MARK: - Registration

func registerComplexGrammarBenchmarks() {
    let seedCount = 1
    let baseSeed: UInt64 = 1337
    let config = Interpreters.ReducerConfiguration.slow

    registerECOOPPair(
        name: "ComplexGrammar",
        gen: #gen(complexGrammarGen(depth: 10)),
        property: complexGrammarProperty,
        config: config,
        seedCount: seedCount,
        baseSeed: baseSeed,
        maxGenerationRuns: 100_000,
        sizeMetric: operatorCount
    )
}

// MARK: - Helpers

private func operatorCount(_ expr: ComplexExpr) -> Int {
    switch expr {
    case .lit:
        0
    case let .add(lhs, rhs):
        1 + operatorCount(lhs) + operatorCount(rhs)
    case let .sub(lhs, rhs):
        1 + operatorCount(lhs) + operatorCount(rhs)
    case let .mul(lhs, rhs):
        1 + operatorCount(lhs) + operatorCount(rhs)
    case let .div(lhs, rhs):
        1 + operatorCount(lhs) + operatorCount(rhs)
    case let .ifThen(condition, thenBranch, elseBranch):
        1 + operatorCount(condition) + operatorCount(thenBranch) + operatorCount(elseBranch)
    case let .call(args):
        1 + args.reduce(0) { $0 + operatorCount($1) }
    }
}

private func containsLiteralDivByZero(_ expr: ComplexExpr) -> Bool {
    switch expr {
    case .lit:
        false
    case .div(_, .lit(0)):
        true
    case let .add(lhs, rhs):
        containsLiteralDivByZero(lhs) || containsLiteralDivByZero(rhs)
    case let .sub(lhs, rhs):
        containsLiteralDivByZero(lhs) || containsLiteralDivByZero(rhs)
    case let .mul(lhs, rhs):
        containsLiteralDivByZero(lhs) || containsLiteralDivByZero(rhs)
    case let .div(lhs, rhs):
        containsLiteralDivByZero(lhs) || containsLiteralDivByZero(rhs)
    case let .ifThen(condition, thenBranch, elseBranch):
        containsLiteralDivByZero(condition)
            || containsLiteralDivByZero(thenBranch)
            || containsLiteralDivByZero(elseBranch)
    case let .call(args):
        args.contains(where: containsLiteralDivByZero)
    }
}

private func complexBackwardLit(_ expr: ComplexExpr) -> Int {
    switch expr {
    case let .lit(value):
        value
    default:
        0
    }
}

private func complexBackwardBinary(_ expr: ComplexExpr) -> (ComplexExpr, ComplexExpr) {
    switch expr {
    case let .add(lhs, rhs):
        (lhs, rhs)
    case let .sub(lhs, rhs):
        (lhs, rhs)
    case let .mul(lhs, rhs):
        (lhs, rhs)
    case let .div(lhs, rhs):
        (lhs, rhs)
    case let .ifThen(condition, thenBranch, _):
        (condition, thenBranch)
    case let .call(args) where args.count >= 2:
        (args[0], args[1])
    case .call, .lit:
        (expr, expr)
    }
}

private func complexBackwardTernary(
    _ expr: ComplexExpr
) -> (ComplexExpr, ComplexExpr, ComplexExpr) {
    switch expr {
    case let .ifThen(condition, thenBranch, elseBranch):
        (condition, thenBranch, elseBranch)
    case let .add(lhs, rhs):
        (lhs, rhs, expr)
    case let .sub(lhs, rhs):
        (lhs, rhs, expr)
    case let .mul(lhs, rhs):
        (lhs, rhs, expr)
    case let .div(lhs, rhs):
        (lhs, rhs, expr)
    case let .call(args) where args.count >= 3:
        (args[0], args[1], args[2])
    case .call, .lit:
        (expr, expr, expr)
    }
}

private func complexBackwardCall(_ expr: ComplexExpr) -> [ComplexExpr] {
    switch expr {
    case let .call(args):
        args
    case let .add(lhs, rhs):
        [lhs, rhs]
    case let .sub(lhs, rhs):
        [lhs, rhs]
    case let .mul(lhs, rhs):
        [lhs, rhs]
    case let .div(lhs, rhs):
        [lhs, rhs]
    case let .ifThen(condition, thenBranch, elseBranch):
        [condition, thenBranch, elseBranch]
    case .lit:
        [expr]
    }
}
