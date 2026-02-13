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
        // let arrGen = Gen.arrayOf(Gen.choose(in: 0...1000), within: 100...1000) produces [VVVVV]
        var count = 0 // This is 5 in this case, which is surprisingly small. 14 for an array of 338 elements.
        let property: ([Int]) -> Bool = { arr in
            count += 1
            return arr.elementsEqual(arr.reversed())
        }
        let iterator = ValueAndChoiceTreeInterpreter(arrGen, seed: 1337)
        let (value, tree) = Array(iterator.dropFirst(2)).first!
        let (seq, output) = try #require(try Interpreters.reduce(gen: arrGen, tree: tree, config: .fast, property: property))
        #expect(value.count > output.count ?? Int.max)
        #expect(output.count == 2)
        print()
    }
}
