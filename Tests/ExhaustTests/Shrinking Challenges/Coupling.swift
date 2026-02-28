//
//  Coupling.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust
@_spi(ExhaustInternal) @testable import ExhaustCore

@MainActor
@Suite("Shrinking Challenge: Coupling")
struct CouplingShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/coupling.md
     In this example the elements of a list of integers are coupled to their position in an unusual way.

     The expected smallest falsified sample is [1, 0].
     */

    // And this one doesn't work.
//    static let gen: ReflectiveGenerator<([Int], Int)> = Gen.zip(
//        Gen.arrayOf(Gen.choose(in: 0...100)),
//        Gen.choose(in: 0...99)
//    ).filter { arr in arr.allSatisfy { arr.indices.contains($0) } }
    // TODO: This generator is not reflective due to the bind
    static let gen: ReflectiveGenerator<[Int]> = Gen.choose(in: Int(0) ... 100)
        .bind { n in
            Gen.arrayOf(Gen.choose(in: 0 ... n), within: 2 ... max(2, UInt64(n) + 1))
        }
        .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

    /// The array cannot contain any 2-cycles, ie where arr[arr[n]] == n
    static let property: ([Int]) -> Bool = { arr in
        arr.indices.allSatisfy { i in
            let j = arr[i]
            if j != i, arr[j] == i {
                return false
            }
            return true
        }
    }

    /// We had this, but Minimax destroyed it
    @Test("Coupling, Single")
    func couplingFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337)
        let (value, tree) = try #require(Array(iterator.prefix(96)).last)
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        #expect(Self.property(value) == false)
        // We expect this array to be shortened to only include the two values that cause a cycle
        // And for those two values to be reduced to [0,1] rather than [15, 4]
        #expect(output.count == 2)
        #expect(output == [1, 0])
    }

    // [2, 4, 13, 11, 10, 2, 0, 6, 2, 2, 13, 12, 3, 10]
    @Test("Coupling, Pathological", .disabled("Value is not reflectable due to `bind`"))
    func couplingPathological() throws {
        let value = [3, 0, 11, 2, 15, 11, 6, 9, 17, 9, 1, 16, 4, 10, 15, 5, 11, 2]
        #expect(Self.property(value) == false)
        // This is not reflectable.
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))

        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        // We expect this array to be shortened to only include the two values that cause a cycle
        // And for those two values to be reduced to [0,1] rather than [15, 4]
        #expect(output.count == 2)
        #expect(output == [1, 0])
    }

    @Test("Coupling, ~75")
    func couplingBatch() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 400)
        for (value, tree) in iterator where Self.property(value) == false {
            let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            #expect(output.count == 2)
            #expect(output == [1, 0])
        }
    }
}
