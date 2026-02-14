//
//  Reverse.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Reverse Shrinking Challenge")
struct ReverseShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/reverse.md
     This tests the (wrong) property that reversing a list of integers results in the same list. It is a basic example to validate that a library can reliably normalize simple sample data.
     */
    @Test("Reverse, Full")
    func reverseFull() async throws {
        let arrGen = Gen.arrayOf(Int.arbitrary, within: 1...1000) // produces [(V)...]
        var count = 0
        let property: ([Int]) -> Bool = { arr in
            count += 1
            return arr.elementsEqual(arr.reversed())
        }
        let iterator = ValueAndChoiceTreeInterpreter(arrGen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(3)).last! // 23 values
        let (_, output) = try #require(try Interpreters.reduce(gen: arrGen, tree: tree, config: .fast, property: property))
        #expect(count == 60) // Oracle/property calls
        #expect(value.count > output.count)
        #expect(output == [0, 1])
    }
}
