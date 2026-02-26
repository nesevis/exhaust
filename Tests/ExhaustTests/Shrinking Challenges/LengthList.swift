//
//  LengthList.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Length List")
struct LengthListShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/lengthlist.md
     A list should be generated first by picking a length between 1 and 100, then by generating a list of precisely that length whose elements are integers between 0 and 1000. The test should fail if the maximum value of the list is 900 or larger.

     This list should specifically be generated using monadic combinators (bind) or some equivalent, and this is a test that is only interesting for integrated shrinking. This is only interesting as a test of a problem some property-based testing libraries have with monadic bind**. In particular the use of the length parameter is critical, and the challenge is to shrink this example to [900] reliably when using a PBT library's built in generator for lists.
     ** https://clojure.github.io/test.check/growth-and-shrinking.html#unnecessary-bind
     */

    static let gen: ReflectiveGenerator<[UInt]> = Gen.arrayOf(Gen.choose(in: UInt(0) ... 1000), within: 1 ... 100)

    static let property: ([UInt]) -> Bool = { arr in
        arr.max() ?? 0 < 900
    }

    @Test("Length List, Full", .disabled("Size scaling changed from logarithmic to linear"))
    func lengthListFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337)
        let (_, tree) = try #require(Array(iterator.prefix(3)).last) // 23 values
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output == [900])
    }
}
