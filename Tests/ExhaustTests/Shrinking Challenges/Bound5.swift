//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Bound5")
struct Bound5ShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/bound5.md
     Given a 5-tuple of lists of 16-bit integers, we want to test the property that if each list sums to less than 256, then the sum of all the values in the lists is less than 5 * 256. This is false because of overflow. e.g. ([-20000], [-20000], [], [], []) is a counter-example.

     The interesting thing about this example is the interdependence between separate parts of the sample data. A single list in the tuple will never break the invariant, but you need at least two lists together. This prevents most of trivial shrinking algorithms from getting close to a minimum example, which would look something like ([-32768], [-1], [], [], []).
     */

    typealias Bound5 = ([Int16], [Int16], [Int16], [Int16], [Int16])

    private static let gen: ReflectiveGenerator<Bound5> = {
        let arrGen = Gen.arrayOf(Int16.arbitrary, within: 0 ... 10)
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return Gen.zip(arrGen, arrGen, arrGen, arrGen, arrGen)
    }()

    private static let property: (Bound5) -> Bool = { arg in
        let (a, b, c, d, e) = arg
        let arr = a + b + c + d + e
        if arr.isEmpty {
            return true
        }
        return arr.dropFirst().reduce(arr[0], &+) < 5 * 256
    }

    @Test("Bound5, Single")
    func bound5Single() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337)
        let (value, tree) = try #require(Array(iterator.prefix(4)).last)
        let sequence = ChoiceSequence.flatten(tree)
        print()
        let smokeTest = try #require(try Interpreters.materialize(Self.gen, with: tree, using: sequence))
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        // ([-1], [-32768], [], [], [])
        let arr = (output.0 + output.1 + output.2 + output.3 + output.4).sorted()
        #expect(arr.count == 2)
        #expect(arr == [-32768, -1])
    }

    @Test("Bound5, Pathological 1")
    func bound5Pathological() throws {
        let value: Bound5 = ([-18914, -2906, 9816], [7672, 16087, 24512], [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885], [25982, 8828, 5007, -6389], [12744, -11152, -18025, -29069, 30825])
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        let sequence = ChoiceSequence.flatten(tree)
        
        let smokeTest = try #require(try Interpreters.materialize(Self.gen, with: tree, using: sequence))
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        let arr = (output.0 + output.1 + output.2 + output.3 + output.4).sorted()
        #expect(arr.count == 2)
        #expect(arr == [-32768, -1])
    }
    
    @Test("Bound5, Pathological 2")
    func bound5Pathological2() throws {
        let value: Bound5 = ([-10709], [29251, 31661], [-18678], [-2824, 15387, -15932, -23458, -6124, 3327, -21001, 16059, -21211, -27710], [16775, -32275, 813, 11044])
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        let sequence = ChoiceSequence.flatten(tree)
        
        let smokeTest = try #require(try Interpreters.materialize(Self.gen, with: tree, using: sequence))
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        let arr = (output.0 + output.1 + output.2 + output.3 + output.4).sorted()
        #expect(arr.count == 2)
        #expect(arr == [-32768, -1])
    }
    
    @Test("Bound5, Pathological 3")
    func bound5Pathological3() throws {
        /*
         ([-11954, 25609, -21279], [20837, 6773, -1304, -13732, -2626, -3440, 15253, 28268, -31908, 30491], [23543, -10339, -12447, 9150, 18335, -2103, 15547, 11124], [-32635, 18394, -23954, 13750, 27692, 25639, 23372, -27650, 18759, 17794], [-6525, 2724, -30958, 28797, -2409, -1095, 2335, -14856])Lo
         */
        let value: Bound5 = ([-11954, 25609, -21279], [20837, 6773, -1304, -13732, -2626, -3440, 15253, 28268, -31908, 30491], [23543, -10339, -12447, 9150, 18335, -2103, 15547, 11124], [-32635, 18394, -23954, 13750, 27692, 25639, 23372, -27650, 18759, 17794], [-6525, 2724, -30958, 28797, -2409, -1095, 2335, -14856])
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        let sequence = ChoiceSequence.flatten(tree)
        
        let smokeTest = try #require(try Interpreters.materialize(Self.gen, with: tree, using: sequence))
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))

        let arr = (output.0 + output.1 + output.2 + output.3 + output.4).sorted()
        #expect(arr.count == 2)
        #expect(arr == [-32768, -1])
    }

    @Test("Bound5, 50")
    func bound5Many() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 100)

        var values = [(before: Bound5, after: Bound5)]()
        for (value, tree) in iterator where Self.property(value) == false {
            let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            values.append((value, output))
        }
        let list = values.enumerated().sorted(by: { lhs, rhs in
            let lhs = lhs.element.after
            let rhs = rhs.element.after
            let lhsCount = lhs.0.count + lhs.1.count + lhs.2.count + lhs.3.count + lhs.4.count
            let rhsCount = rhs.0.count + rhs.1.count + rhs.2.count + rhs.3.count + rhs.4.count
            return lhsCount < rhsCount
        })

//        for (offset, values) in values.enumerated() {
//            let (before, after) = values
//            print("\(offset + 1): \(after) original: \(before)")
//        }
    }
}
