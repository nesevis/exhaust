//
//  Calculator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Calculator")
struct CalculatorShrinkingChallenge {
    indirect enum Expr: Equatable {
        case value(Int)
        case add(Expr, Expr)
        case div(Expr, Expr)
    }

    enum EvalError: Error {
        case divisionByZero
    }

    static func eval(_ expr: Expr) throws -> Int {
        switch expr {
        case let .value(value):
            return value
        case let .add(lhs, rhs):
            return try eval(lhs) + eval(rhs)
        case let .div(lhs, rhs):
            let denominator = try eval(rhs)
            guard denominator != 0 else {
                throw EvalError.divisionByZero
            }
            return try eval(lhs) / denominator
        }
    }

    static func containsLiteralDivisionByZero(_ expr: Expr) -> Bool {
        switch expr {
        case .value:
            return false
        case let .add(lhs, rhs):
            return containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
        case let .div(lhs, rhs):
            if case .value(0) = rhs {
                return true
            }
            return containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
        }
    }

    static func expression(depth: UInt64) -> ReflectiveGenerator<Expr> {
        let literal = Gen.choose(in: Int(-10) ... 10).map(Expr.value)

        guard depth > 0 else {
            return literal
        }

        let child = expression(depth: depth - 1)
        let add = Gen.zip(child, child).map(Expr.add)
        let divide = Gen.zip(child, child).map(Expr.div)

        return Gen.pick(choices: [
            (2, literal),
            (3, add),
            (3, divide),
        ])
    }

    static let gen: ReflectiveGenerator<Expr> = expression(depth: 4)

    static let property: (Expr) -> Bool = { expr in
        guard containsLiteralDivisionByZero(expr) == false else {
            return true
        }
        do {
            _ = try eval(expr)
            return true
        } catch EvalError.divisionByZero {
            return false
        } catch {
            return false
        }
    }

    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/calculator.md
     The challenge involves a simple calculator language representing expressions consisting of integers, their additions and divisions only, like 1 + (2 / 3).

     The property being tested is that

     if we have no subterms of the form x / 0,
     then we can evaluate the expression without a zero division error.
     This property is false, because we might have a term like 1 / (3 + -3), in which the divisor is not literally 0 but evaluates to 0.

     One of the possible difficulties that might come up is the shrinking of recursive expressions.
     */
    @Test("Calculator, Full")
    func calculatorFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337, maxRuns: 2_000)
        let (value, tree) = try #require(iterator.first(where: { Self.property($0.0) == false }))
        let originalSeq = ChoiceSequence.flatten(tree)

        let (seq, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        #expect(Self.containsLiteralDivisionByZero(output) == false)
        #expect(Self.property(output) == false)
        print("before: \(originalSeq.shortString)")
        print("after:  \(seq.shortString)")
        print()
//        #expect(output == .div(.value(0), .add(.value(0), .value(0))))
    }
}
