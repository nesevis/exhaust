//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@MainActor
@Suite("Shrinking Challenge: Coupling")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */
    
    static let gen: ReflectiveGenerator<[Int]> = {
//        Gen.arrayOf(Gen.choose(in: Int(0)...19), within: 2...20)
//            .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }
        Gen.choose(in: Int(0)...100)
            .bind { n in
                Gen.arrayOf(Gen.choose(in: 0...n), within: 2...max(2, (UInt64(n)+1)))
            }
            .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }
    }()
    
    // The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
    static let property: ([Int]) -> Bool = { arr in
        arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i && arr[j] == i {
                return false
            }
            return true
        }
    }
    
    @Test("Coupling, Single")
    // We had this, but Minimax destroyed it
    func couplingFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(4)).last!
        let (seq, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        
        // We expect this array to be shortened to only include the two values that cause a cycle
        // And for those two values to be reduced to [0,1] rather than [15, 4]
        #expect(output.count == 2)
        #expect(output == [1, 0])
    }
    
    @Test("Coupling, 50")
    // We had this, but Minimax destroyed it
    func couplingBatch() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337, maxRuns: 50)
        var outputs = [(b: [Int], a: [Int])]()
        for (value, tree) in iterator where Self.property(value) == false {
            let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            outputs.append((value, output))
        }
        
        for (index, output) in outputs.enumerated() {
            print("\(index + 1) input: \(output.b) — reduced: \(output.a)")
//            #expect(output.a.count == 2)
//            #expect(output.a == [1, 0])
        }
    }
    
    /*
     We're not doing too well here. Original values in parenthesis
     1 [0, 0] ([0, 0])
     2 [0, 1] ([0, 1])
     3 [1, 0] ([1, 0, 2])
     4 [0, 0] ([0, 0])
     5 [0, 0] ([0, 0])
     6 [1, 0] ([1, 0])
     7 [1, 0] ([2, 1, 0])
     8 [1, 0, 0, 0, 0, 0, 0, 0, 0] ([4, 0, 1, 1, 8, 10, 3, 0, 11, 0, 1, 9])
     9 [0, 0, 14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2] ([1, 1, 14, 13, 0, 4, 14, 10, 1, 10, 14, 1, 4, 0, 5, 2])
     10 [0, 2, 0, 2, 2] ([0, 2, 0, 2, 2])
     11 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([7, 4, 9, 1, 4, 10, 0, 5, 9, 7, 7, 7])
     12 [1, 0] ([1, 1])
     13 [1, 0, 0, 0, 0, 0, 0, 0, 0] ([8, 8, 0, 4, 1, 5, 8, 2, 2])
     14 [1, 0, 0] ([2, 2, 1, 0])
     15 [1, 0, 0, 0] ([2, 1, 1, 2])
     16 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([11, 1, 8, 11, 8, 10, 3, 0, 7, 2, 11, 7])
     17 [1, 0, 0, 0, 0] ([3, 4, 0, 1, 1])
     18 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([15, 11, 5, 13, 6, 13, 15, 14, 7, 5, 2, 10, 12, 13, 10, 13, 7])
     19 [0, 0] ([0, 0])
     20 [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 12, 11] ([6, 11, 10, 8, 11, 6, 8, 3, 5, 7, 1, 12, 11])
     21 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([6, 11, 10, 4, 3, 0, 5, 0, 7, 11, 2, 1])
     22 [0, 0] ([0, 0])
     23 [1, 0, 0, 0, 0] ([3, 5, 0, 2, 1, 2])
     24 [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 23, 0, 0, 20] ([11, 19, 23, 12, 23, 11, 0, 2, 6, 23, 23, 19, 5, 9, 14, 7, 9, 23, 9, 21, 23, 3, 18, 13, 20])
     25 [1, 0, 0, 0] ([2, 3, 1, 1])
     26 [0, 0, 0, 0, 0, 7, 0, 5, 0] ([0, 1, 7, 0, 8, 4, 9, 7, 6, 5, 8])
     27 [0, 2, 1] ([0, 2, 1])
     28 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([2, 1, 4, 8, 5, 13, 4, 13, 6, 6, 2, 1, 0, 13])
     29 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([6, 7, 9, 2, 3, 0, 2, 8, 4, 10, 2, 0])
     30 [1, 0] ([1, 0])
     31 [1, 0, 0, 0] ([4, 0, 2, 0, 3])
     32 [0, 0] ([0, 0])
     33 [0, 0, 0, 5, 0, 3] ([2, 3, 5, 5, 1, 3])
     34 [1, 0, 0, 0, 0, 0, 0, 0] ([6, 16, 4, 16, 16, 16, 7, 0, 3, 8, 0, 3, 9, 10, 8, 0, 8])
     35 [0, 1] ([0, 1])
     36 [0, 0, 0, 0, 0, 0, 7, 6] ([5, 2, 2, 0, 4, 5, 7, 6, 0])
     37 [1, 0, 0] ([3, 0, 1, 2])
     38 [1, 0, 0, 0] ([3, 3, 1, 3])
     39 [0, 0] ([0, 0])
     40 [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] ([15, 12, 15, 12, 7, 11, 10, 13, 4, 9, 7, 9, 8, 13, 2, 6, 11, 4])
     41 [1, 0, 0, 0, 0] ([3, 11, 6, 8, 3, 5, 12, 11, 4, 9, 10, 4, 14, 7, 13])
     42 [1, 0, 0, 0, 0, 0, 0] ([3, 1, 4, 1, 7, 5, 0, 0])
     43 [0, 0, 1] ([0, 0, 1])
     44 [0, 0] ([0, 0])
     45 [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 11, 0] ([3, 0, 11, 2, 15, 11, 6, 9, 17, 9, 1, 16, 4, 10, 15, 5, 11, 2])
     46 [0, 0] ([0, 0])
     47 [0, 0] ([0, 0])
     48 [1, 0] ([2, 1, 0])
     49 [1, 0] ([1, 0])
     50 [1, 0, 0] ([1, 1, 1])
     */
}
