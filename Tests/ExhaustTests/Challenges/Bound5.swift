//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

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
        let arrGen = Gen.arrayOf(Int16.arbitrary, within: 0...10)
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return Gen.zip(arrGen, arrGen, arrGen, arrGen, arrGen)
    }()
    
    private static let property: (Bound5) -> Bool = { (arg) in
        let (a, b, c, d, e) = arg
        let arr = a + b + c + d + e
        return arr.isEmpty == false && arr.dropFirst().reduce(arr[0], &+) < 5 * 256
    }
    
    @Test("Bound5, Single")
    func bound5Single() throws {
        
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(4)).last!
        let sequence = ChoiceSequence.flatten(tree)
        print()
        let smokeTest = try #require(try Interpreters.materialize(Self.gen, with: tree, using: sequence))
        #expect(value.0 == smokeTest.0 && value.1 == smokeTest.1 && value.2 == smokeTest.2 && value.3 == smokeTest.3 && value.4 == smokeTest.4)
        print()
        let (seq, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        print("Original value: \(value)")
        print("Output: \(output)")
        print("Expected output(ish): ([-32768], [-1], [], [], [])")
    }
    
    @Test("Bound5, 50")
    func bound5Many() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337, maxRuns: 50)
        
        var values = [Bound5]()
        for (value, tree) in iterator where Self.property(value) == false {
            let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            values.append(output)
        }
        let list = values.enumerated().sorted(by: { lhs, rhs in
            let lhsCount = lhs.element.0.count + lhs.element.1.count + lhs.element.2.count + lhs.element.3.count + lhs.element.4.count
            let rhsCount = rhs.element.0.count + rhs.element.1.count + rhs.element.2.count + rhs.element.3.count + rhs.element.4.count
            return lhsCount < rhsCount
        })
        
        for (offset, value) in list {
            print("\(offset + 1): \(String(describing: value).prefix(50))")
        }
    }
}
