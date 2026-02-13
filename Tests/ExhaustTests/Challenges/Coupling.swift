//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Coupling Shrinking Challenge")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */
    @Test("Coupling, Full")
    func couplingFull() throws {
        // A generator that will create an array of length 2...10 with elements corresponding to possible indices
        let gen = Gen.choose(in: Int(2)...20)
            .bind { n in
                Gen.arrayOf(Gen.choose(in: 0...n - 1), exactly: UInt64(n))
            }
        
        // The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
        var count = 0
        let property: ([Int]) -> Bool = { arr in
            print("Arr count: \(arr.count), indices within bounds \(arr.allSatisfy { arr.indices.contains($0) })")
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
        print()
        let (seq, output) = try #require(try Interpreters.reduce(gen: gen, tree: tree, config: .fast, property: property))
        
        // We expect this array to be shortened to only include the two values that cause a cycle
        // And for those two values to be reduced to [0,1] rather than [15, 4]
        /*
         └── group
             ├── choice(signed: 18) 2...20
             └── sequence(length: 18) 18...18 // This is the issue. It can't shrink the length, so the positions/indices can't be shrunk either
                 ├── choice(signed: 2) 0...17
                 ├── choice(signed: 7) 0...17
                 ├── choice(signed: 7) 0...17
                 ├── choice(signed: 4) 0...17
                 ├── choice(signed: 15) 0...17
                 ├── choice(signed: 16) 0...17
                 ├── choice(signed: 6) 0...17
                 ├── choice(signed: 10) 0...17
                 ├── choice(signed: 10) 0...17
                 ├── choice(signed: 16) 0...17
                 ├── choice(signed: 9) 0...17
                 ├── choice(signed: 3) 0...17
                 ├── choice(signed: 17) 0...17
                 ├── choice(signed: 2) 0...17
                 ├── choice(signed: 8) 0...17
                 ├── choice(signed: 4) 0...17
                 ├── choice(signed: 11) 0...17
         */
        #expect(output.count == 2)
        print()
        
        // Will require a value reduction pass
    }
}
