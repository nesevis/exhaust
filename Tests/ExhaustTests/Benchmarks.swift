//
//  Benchmarks.swift
//  Exhaust
//
//  Created by Chris Kolbu on 14/8/2025.
//

import Testing
@testable import Exhaust
import OSLog

let signposter = OSSignposter(
    subsystem: "com.example.apple-samplecode.MyBinarySearch",
    category: .pointsOfInterest
)
@Test("Profile mem alloc")
func testProfileMemAllocations() throws {
    let generator = String.arbitrary
    var iterator = ValueAndChoiceTreeGenerator(generator, materializePicks: true, seed: 1, maxRuns: 100)
    let interval = signposter.beginInterval("prop")
    while let (value, tree) = iterator.next() {
        let value = value
        let tree = tree
    }
    signposter.endInterval("prop", interval, "finished")
//            for n in 1...200 {
//            }
}
