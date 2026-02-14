//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Large Union List Shrinking Challenge")
struct LargeUnionListShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/large_union_list.md
     Given a list of lists of arbitrary sized integers, we want to test the property that there are no more than four distinct integers across all the lists. This is trivially false, and this example is an artificial one to stress test a shrinker's ability to normalise (always produce the same output regardless of starting point).

     In particular, a shrinker cannot hope to normalise this unless it is able to either split or join elements of the larger list. For example, it would have to be able to transform one of [[0, 1, -1, 2, -2]] and [[0], [1], [-1], [2], [-2]] into the other.
     */
    @Test("Large Union List, Full")
    func largeUnionListFull() throws {
        let arrGen = Gen.arrayOf(Int.arbitrary, within: 1...10)
        let gen = Gen.arrayOf(arrGen, within: 1...10)
        
        var count = 0
        let property: ([[Int]]) -> Bool = { arr in
            count += 1
            return Set(arr.flatMap(\.self)).count <= 4
        }
        
        let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(3)).last! // 23 values
        let (sequence, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))
        print()
        #expect(output.flatMap(\.self) == [-2, -1, 0, 1, 2])
    }
}
