//
//  Calculator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Calculator")
struct CalculatorShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/calculator.md
     The challenge involves a simple calculator language representing expressions consisting of integers, their additions and divisions only, like 1 + (2 / 3).

     The property being tested is that

     if we have no subterms of the form x / 0,
     then we can evaluate the expression without a zero division error.
     This property is false, because we might have a term like 1 / (3 + -3), in which the divisor is not literally 0 but evaluates to 0.

     One of the possible difficulties that might come up is the shrinking of recursive expressions.
     */

    @Test("Calculator, Full")
    func calculatorFull() {
        let gen = #gen(CalculatorFixture.expression(depth: 5))
        let result = #exhaust(
            gen,
            .suppress(.issueReporting),
            .budget(.extensive)
        ) { expr in
            CalculatorFixture.property(expr)
        }
        #expect(result == .div(.value(0), .add(.value(0), .value(0))))
    }
    
    // This test ought to reduce to the minimal CE, but a bug fix that allowed for multiple bind-inner leaf scope dispatches surfaced a 1.4% counterexample:
    // 98.6% div(value(0), add(value(0), value(0))) (986 seeds)
    // 1.4% div(value(0), div(value(0), value(-1)))
    @Test("Calculator pathological 1")
    func calculatorPathological1() {
        let gen = #gen(CalculatorFixture.expression(depth: 5))
        let result = #exhaust(
            gen,
            .suppress(.issueReporting),
            .replay(.numeric(1509)),
            .logging(.debug),
            .budget(.extensive)
        ) { expr in
            CalculatorFixture.property(expr)
        }
        #expect(result == .div(.value(0), .add(.value(0), .value(0))))
    }
}
