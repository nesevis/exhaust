//
//  Calculator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustCore

@MainActor
@Suite("Shrinking Challenge: Calculator")
struct CalculatorShrinkingChallenge {
    indirect enum Expr: Equatable {
        case value(Int)
        case add(Expr, Expr)
        case div(Expr, Expr)

        var value: Int? {
            guard case let .value(value) = self else {
                return nil
            }
            return value
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
        case let .div(lhs, .value(0)):
            true
        case let .div(lhs, rhs):
            containsLiteralDivisionByZero(lhs) || containsLiteralDivisionByZero(rhs)
        }
    }

    static func expression(depth: UInt64) -> ReflectiveGenerator<Expr> {
        let leaf = Gen.choose(in: Int(-10) ... 10)
            .mapped(forward: { Expr.value($0) }, backward: { $0.value ?? 0 })

        guard depth > 0 else {
            return leaf
        }

        let child = expression(depth: depth - 1)

        let add = Gen.zip(child, leaf)
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
        let div = Gen.zip(leaf, child)
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

        return Gen.pick(choices: [
            (3, leaf),
            (3, add),
            (3, div),
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
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 100)
        let (value, tree) = try #require(iterator.filter { Self.property($0.0) == false }.last)
        let originalSeq = ChoiceSequence.flatten(tree)
//        print(value)
        print(originalSeq.shortString)

        // It fails the materialisation step here. No changes have happened
        let (seq, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        #expect(Self.containsLiteralDivisionByZero(output) == false)
        #expect(Self.property(output) == false)
        print("before: \(originalSeq.shortString)")
        print("after: \(seq.shortString)")
//        print()
        #expect(output == .div(.value(0), .div(.value(0), .value(1))))
    }

    @Test("Test branch reflection and materialization")
    func branchReflectionAndMaterialisation() throws {
        let simple = Expr.value(1)
        let add = Expr.add(simple, simple)
        let div = Expr.div(simple, simple)

        for expr in [simple, add, div] {
            let reflected = try #require(try Interpreters.reflect(Self.gen, with: expr))
            let sequence = ChoiceSequence.flatten(reflected)
//            print(reflected.debugDescription)
//            print(sequence.shortString)
            let materialized = try Interpreters.materialize(Self.gen, with: reflected, using: sequence)
            #expect(materialized == expr)
        }
    }

    @Test("Test branch replacement")
    func branchReplacement() throws {
        let exprs = Array(ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 10)).dropFirst(5)
        for (value, tree) in exprs {
            let branches = Self.extractBranches(in: tree)
//            print(ChoiceSequence.flatten(tree).shortString)
            for branch in branches.dropFirst(1) {
                let replaced = Self.replaceBranch(at: branches[0].fingerprint, tree: tree, with: branch.node)
                let replacedSequence = ChoiceSequence.flatten(replaced)
//                print(tree.debugDescription)
//                print(ChoiceSequence.flatten(replaced).shortString)
                do {
                    let materialized = try #require(try Interpreters.materialize(Self.gen, with: replaced, using: replacedSequence))
//                    print("materialized successfully:")
//                    print("before: \(value)")
//                    print("after: \(materialized)")
                } catch {
//                    print("materialization failed: \(error)")
                }
            }
//            print()
        }
    }

    private static func extractBranches(in tree: ChoiceTree) -> [(fingerprint: Fingerprint, node: ChoiceTree)] {
        var results: [(fingerprint: Fingerprint, node: ChoiceTree)] = []
        for element in tree.walk() {
            if case .branch = element.node {
                results.append((element.fingerprint, element.node))
            }
        }
        return results
    }

    private static func replaceBranch(at fingerprint: Fingerprint, tree: ChoiceTree, with replacement: ChoiceTree) -> ChoiceTree {
        var result = tree
        let existing = result[fingerprint]
        result[fingerprint] = existing.isSelected
            ? .selected(replacement.unwrapped)
            : replacement
        return result
    }
}

extension CalculatorShrinkingChallenge.Expr: CustomDebugStringConvertible, CustomStringConvertible {
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
