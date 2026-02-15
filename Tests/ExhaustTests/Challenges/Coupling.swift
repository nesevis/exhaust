//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Shrinking Challenge: Coupling")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */
    @Test("Coupling, Full")
    // We had this, but Minimax destroyed it
    func couplingFull() throws {
        let gen = Gen.choose(in: Int(0)...19)
            .bind { n in
                Gen.arrayOf(Gen.choose(in: 0...n), within: 2...20)
            }
        
        // The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
        var count = 0
        let property: ([Int]) -> Bool = { arr in
            count += 1
            // This crashed binarySearchWithGuess.. Wtf?
            return arr.indices.allSatisfy { index in
                let lhs = arr[index]
                if lhs != index {
                    return arr[lhs] != index
                }
                return true
            }
        }
        
        let iterator = ValueAndChoiceTreeInterpreter(gen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(2)).last!
        let (seq, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))
        
        // We expect this array to be shortened to only include the two values that cause a cycle
        // And for those two values to be reduced to [0,1] rather than [15, 4]
        #expect(count == 26)
        #expect(output.count == 2)
        #expect(output == [1, 0])
    }
}
