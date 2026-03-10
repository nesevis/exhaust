//
//  LargeUnionList.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

import ExhaustCore
import Foundation
import Testing
@testable import Exhaust

@MainActor
@Suite("Shrinking Challenge: Large Union List")
struct LargeUnionListShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/large_union_list.md
     Given a list of lists of arbitrary sized integers, we want to test the property that there are no more than four distinct integers across all the lists. This is trivially false, and this example is an artificial one to stress test a shrinker's ability to normalise (always produce the same output regardless of starting point).

     In particular, a shrinker cannot hope to normalise this unless it is able to either split or join elements of the larger list. For example, it would have to be able to transform one of [[0, 1, -1, 2, -2]] and [[0], [1], [-1], [2], [-2]] into the other.
     */

    static let gen: ReflectiveGenerator<[[Int]]> = #gen(.int().array(length: 1 ... 10).array(length: 1 ... 10))

    static let property: ([[Int]]) -> Bool = { arr in
        Set(arr.flatMap(\.self)).count <= 4
    }

    @Test("Large Union List, Single")
    func largeUnionListFull() throws {
        var iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337)
        let (_, tree) = try #require(iterator.prefix(93).last)
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output.flatMap(\.self) == [0, -1, 1, -2, 2])
    }

    @Test("Large Union List, Pathological single")
    func largeUnionListPathological() throws {
        let value = [
            [-40_236_158_320_423_685, 56_599_776_734_305_647, -110_764_793_782_677_473],
            [-173_728_398_250_472_629],
            [-92_071_603_954_950_552],
        ]
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        print()
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output.flatMap(\.self) == [0, -1, 1, -2, 2])
    }

    @Test("Large Union List, Pathological single 2")
    func largeUnionListPathological2() throws {
        let value = [[-140_165_314_328_449, 79_003_739_596_584, -102_880_757_906_973, 59_059_092_428_908, 118_937_662_940_338, 110_119_751_840_770, 100_385_325_416_037, -118_755_354_749_898, 80_572_987_607_965, 76_424_960_810_766], [-28_023_762_322_669, 11_702_849_741_616, -132_960_251_314_433, 123_682_815_435_579, -10_343_261_662_018, -4_700_527_354_204, 10_032_215_627_723, -63_802_894_155_092, -103_439_992_132_983], [-31_190_610_291_605, -125_312_221_647_467, -67_770_770_878_048, 74_921_319_749_072, -34_565_939_758_906, -48_688_160_340_287, 18_293_331_003_577, 67_560_200_516_186], [-77_447_398_498_565, -126_080_081_874_646, -63_017_712_975_195, 86_926_291_646_097], [-89_717_625_244_173, -10_050_986_803_917, 10_364_103_939_241, -93_995_600_961_861, 31_194_551_855_121, -132_988_363_192_036, -96_151_068_047_749], [-22_614_648_784_524, -18_194_426_629_298, 123_098_101_697_801, 73_283_960_328_215, -24_300_919_081_696, -18_576_827_148_737, -71_742_940_518_794], [-6_813_118_022_644, 57_217_985_601_415, -6_180_874_521_902, -136_303_770_089_928]]
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        print()
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output.flatMap(\.self) == [0, -1, 1, -2, 2])
    }

    @Test("Large Union List, Pathological single 3")
    func largeUnionListPathological3() throws {
        let value = [[76132], [-61180, -48610, 71763], [-25593]]
        let tree = try #require(try Interpreters.reflect(Self.gen, with: value))
        let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
        #expect(output.flatMap(\.self) == [0, -1, 1, -2, 2])
    }

    @Test("Large Union List, 50")
    func largeUnionListBatch() throws {
        var iterator = ValueAndChoiceTreeInterpreter(Self.gen, materializePicks: true, seed: 1337, maxRuns: 100)

        var outputs = [(value: [[Int]], shrunk: [[Int]])]()
        while let (value, tree) = try iterator.next() {
            guard Self.property(value) == false, outputs.count <= 50 else { continue }
            let (_, output) = try #require(try Interpreters.reduce(gen: Self.gen, tree: tree, config: .fast, property: Self.property))
            outputs.append((value, output))
        }

        for (index, output) in outputs.enumerated() {
            let (value, output) = output
            let flat = output.flatMap(\.self)
            // Shortlex-minimal 5 distinct integers: [0, -1, 1, -2, 2] (keys [0, 1, 2, 3, 4])
            let keys = flat.map { ChoiceValue(Int64($0), tag: .int64).shortlexKey }
            let pass = output.count == 1 && flat.count == 5
                && Set(flat).count == 5 && keys == keys.sorted()

            // Expect there to be one nested array
            #expect(output.count == 1)
            // Expect there to be five entries in this array
            let array = try #require(output.first)
            #expect(array.count == 5)

            // Expect the values to be in shortlex order (closest to zero first)
            let arrayKeys = array.map { ChoiceValue(Int64($0), tag: .int64).shortlexKey }
            #expect(arrayKeys == arrayKeys.sorted())

            if !pass {
                print("Fail on original [\(index)] \(value) shrunk \(output)")
                break
            }
        }
    }
}
