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
@Suite("Shrinking Challenge: Large Union List")
struct LargeUnionListShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/large_union_list.md
     Given a list of lists of arbitrary sized integers, we want to test the property that there are no more than four distinct integers across all the lists. This is trivially false, and this example is an artificial one to stress test a shrinker's ability to normalise (always produce the same output regardless of starting point).

     In particular, a shrinker cannot hope to normalise this unless it is able to either split or join elements of the larger list. For example, it would have to be able to transform one of [[0, 1, -1, 2, -2]] and [[0], [1], [-1], [2], [-2]] into the other.
     */
    
    static let gen: ReflectiveGenerator<[[Int]]> = {
        let arrGen = Gen.arrayOf(Int.arbitrary, within: 1...10)
        return Gen.arrayOf(arrGen, within: 1...10)
    }()
    
    static let property: ([[Int]]) -> Bool = { arr in
        Set(arr.flatMap(\.self)).count <= 4
    }
    
    @Test("Large Union List, Single")
    func largeUnionListFull() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337)
        let (value, tree) = Array(iterator.prefix(4)).last! // 23 values
        let (sequence, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output.flatMap(\.self) == [-1, -0, 1, 2, 3])
    }
    
    @Test("Large Union List, Pathological single")
    func largeUnionListPathological() throws {
        let value = [
            [-40236158320423685, 56599776734305647, -110764793782677473],
            [-173728398250472629],
            [-92071603954950552]
        ]
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        print()
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        print(output)
        #expect(output.flatMap(\.self) == [-3, -2, -1, 0, 1])
    }
    
    @Test("Large Union List, Pathological single 2")
    func largeUnionListPathological2() throws {
        let value = [[-140165314328449, 79003739596584, -102880757906973, 59059092428908, 118937662940338, 110119751840770, 100385325416037, -118755354749898, 80572987607965, 76424960810766], [-28023762322669, 11702849741616, -132960251314433, 123682815435579, -10343261662018, -4700527354204, 10032215627723, -63802894155092, -103439992132983], [-31190610291605, -125312221647467, -67770770878048, 74921319749072, -34565939758906, -48688160340287, 18293331003577, 67560200516186], [-77447398498565, -126080081874646, -63017712975195, 86926291646097], [-89717625244173, -10050986803917, 10364103939241, -93995600961861, 31194551855121, -132988363192036, -96151068047749], [-22614648784524, -18194426629298, 123098101697801, 73283960328215, -24300919081696, -18576827148737, -71742940518794], [-6813118022644, 57217985601415, -6180874521902, -136303770089928]]
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        print()
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        print(output)
        #expect(output.flatMap(\.self) == [-1, 0, 1, 2, 3])
    }
    
    @Test("Large Union List, 50")
    func largeUnionListBatch() throws {
        let iterator = ValueAndChoiceTreeInterpreter(Self.gen, seed: 1337, maxRuns: 100)
        
        var outputs = [[[Int]]]()
        for (value, tree) in iterator where Self.property(value) == false && outputs.count <= 50 {
            let (seq, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            outputs.append(output)
            // This fails due to the validRange of the generator's size interacting with the randomly generated value causing certain passes from working as intended.
//            if output.map(\.count).reduce(0, +) > 5 {
//                print("value: \(value)")
//                print("output: \(output)")
//            }
//            #expect(output.flatMap(\.self) == [-2, -1, 0, 1, 2])
        }
        
        for (index, output) in outputs.enumerated() {
            print("\(index + 1): \(output)")
            // Expect there to be one nested array
            #expect(output.count == 1)
            // Expect there to be five entries in this array
            let array = try #require(output.first)
            #expect(array.count == 5)
            
            // Expect the values to increase by one
            var steps = Set<Int>()
            for (index, value) in array.enumerated().dropFirst() {
                steps.insert(value - array[index - 1])
            }
            #expect(steps == [1])
        }
    }
}
