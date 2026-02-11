//
//  Calculator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Calculator Shrinking Challenge")
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
    @Test("Calculator, Full", .disabled("Not implemented"))
    func calculatorFull() {
        // …etc
    }
}
