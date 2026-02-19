//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@Suite("Shrinking Challenge: Reverse")
struct ReverseShrinkingChallenge {
    /**
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/reverse.md
     This tests the (wrong) property that reversing a list of integers results in the same list. It is a basic example to validate that a library can reliably normalize simple sample data.
     */
    @Test("Reverse, Full")
    func reverseFull() throws {
        // Using UInts for consistency, as signed numbers can reduce to -1 or 1
        let arrGen = Gen.arrayOf(UInt.arbitrary, within: 1 ... 1000) // produces [(V)...]
        var count = 0
        let property: ([UInt]) -> Bool = { arr in
            count += 1
            return arr.elementsEqual(arr.reversed())
        }
        let iterator = ValueAndChoiceTreeInterpreter(arrGen, materializePicks: true, seed: 1337)
        let (value, tree) = try #require(Array(iterator.prefix(3)).last) // 23 values
        let (_, output) = try #require(try Interpreters.reduce(gen: arrGen, tree: tree, config: .fast, property: property))
        #expect(count == 53) // Oracle/property calls
        #expect(value.count > output.count)
        #expect(output == [0, 1])
    }
}
