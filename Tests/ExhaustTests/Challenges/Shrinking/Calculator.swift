//
//  Calculator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Calculator")
struct CalculatorShrinkingChallenge {
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
        let gen = #gen(Self.expression(depth: 4))
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        let result = #exhaust(
            gen,
            .suppressIssueReporting,
            .useBonsaiReducer,
            .replay(1117838118804311299)
        ) { expr in
            guard Self.containsLiteralDivisionByZero(expr) == false else {
                return true
            }
            do {
                _ = try Self.eval(expr)
                return true
            } catch EvalError.divisionByZero {
                return false
            } catch {
                return false
            }
        }

        print("Output: \(result!)")
        #expect(
            result == .div(.value(0), .div(.value(0), .value(1))) ||
            result == .div(.value(0), .div(.value(0), .value(-1))) ||
            // The Bonsai reducer gets it to the minimum!
            result == .div(.value(0), .add(.value(0), .value(0)))
        )
    }
    
    // MARK: - Types
    
    indirect enum Expr: Equatable, CustomDebugStringConvertible, CustomStringConvertible {
        case value(Int)
        case add(Expr, Expr)
        case div(Expr, Expr)

        var value: Int? {
            guard case let .value(value) = self else {
                return nil
            }
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
            false
        case let .add(lhs, rhs):
            containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
        case .div(_, .value(0)):
            true
        case let .div(lhs, rhs):
            containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
        }
    }

    static func expression(depth: UInt64) -> ReflectiveGenerator<Expr> {
        let leaf = #gen(.int(in: -10 ... 10))
            .mapped(forward: { Expr.value($0) }, backward: { $0.value ?? 0 })

        guard depth > 0 else {
            return leaf
        }

        let child = expression(depth: depth - 1)

        let add = #gen(child, leaf)
            .mapped(
                forward: { lhs, rhs in Expr.add(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                },
            )
        let div = #gen(leaf, child)
            .mapped(
                forward: { lhs, rhs in Expr.div(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                },
            )

        return #gen(.oneOf(weighted:
            (3, leaf),
            (3, add),
            (3, div)))
    }
}
