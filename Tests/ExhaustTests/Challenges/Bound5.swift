//
//  Bound5.swift
//  Exhaust
//
//  Created by Chris Kolbu on 11/2/2026.
//

@testable import Exhaust
import Foundation
import Testing

@Suite("Bound5 Shrinking Challenge")
struct Bound5ShrinkingChallenge {
    /*
     https://github.com/jlink/shrinking-challenge/blob/main/challenges/bound5.md
     Given a 5-tuple of lists of 16-bit integers, we want to test the property that if each list sums to less than 256, then the sum of all the values in the lists is less than 5 * 256. This is false because of overflow. e.g. ([-20000], [-20000], [], [], []) is a counter-example.

     The interesting thing about this example is the interdependence between separate parts of the sample data. A single list in the tuple will never break the invariant, but you need at least two lists together. This prevents most of trivial shrinking algorithms from getting close to a minimum example, which would look something like ([-32768], [-1], [], [], []).
     */
    @Test("Bound5, Full", .disabled("Not implemented"))
    func bound5Full() {
        let arrGen = Gen.arrayOf(Int16.arbitrary, within: 1...10)
        let gen = Gen.zip(arrGen, arrGen, arrGen, arrGen, arrGen)
        
        // …etc
    }
}
