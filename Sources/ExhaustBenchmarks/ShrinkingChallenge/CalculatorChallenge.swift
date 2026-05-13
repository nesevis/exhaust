import Exhaust

// MARK: - Type

indirect enum Expr: Equatable, CustomDebugStringConvertible, CustomStringConvertible {
    case value(Int)
    case add(Expr, Expr)
    case div(Expr, Expr)

    var value: Int? {
        guard case let .value(value) = self else { return nil }
        return value
    }

    var debugDescription: String {
        switch self {
        case let .value(value):
            "value(\(value))"
        case let .add(lhs, rhs):
            "add(\(lhs.debugDescription), \(rhs.debugDescription))"
        case let .div(lhs, rhs):
            "div(\(lhs.debugDescription), \(rhs.debugDescription))"
        }
    }

    var description: String {
        debugDescription
    }
}

// MARK: - Evaluation (with bug)

enum EvalError: Error {
    case divisionByZero
}

func eval(_ expr: Expr) throws -> Int {
    switch expr {
    case let .value(value):
        return value
    case let .add(lhs, rhs):
        return try eval(lhs) &+ eval(rhs)
    case let .div(lhs, rhs):
        let denominator = try eval(rhs)
        guard denominator != 0 else { throw EvalError.divisionByZero }
        return try eval(lhs) / denominator
    }
}

func containsLiteralDivisionByZero(_ expr: Expr) -> Bool {
    switch expr {
    case .value:
        false
    case let .add(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    case .div(_, .value(0)):
        true
    case let .div(lhs, rhs):
        containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
    }
}

// MARK: - Generator

func calculatorExpressionGen(depth: UInt64) -> ReflectiveGenerator<Expr> {
    let leaf = #gen(.int())
        .mapped(forward: { Expr.value($0) }, backward: { $0.value ?? 0 })

    return #gen(.recursive(base: leaf, depthRange: 0 ... depth) { recurse, _ in
        let add = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in Expr.add(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )
        let div = #gen(recurse(), recurse())
            .mapped(
                forward: { lhs, rhs in Expr.div(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )

        return .oneOf(weighted:
            (3, leaf),
            (3, add),
            (3, div))
    })
}

// MARK: - Property

let calculatorProperty: @Sendable (Expr) -> Bool = { expr in
    guard containsLiteralDivisionByZero(expr) == false else { return true }
    do {
        _ = try eval(expr)
        return true
    } catch {
        return false
    }
}
