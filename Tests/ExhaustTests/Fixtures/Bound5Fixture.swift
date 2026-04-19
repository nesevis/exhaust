//
//  Bound5Fixture.swift
//  ExhaustTests
//
//  Shared fixture for the ECOOP shrinking challenge "Bound5":
//  https://github.com/jlink/shrinking-challenge/blob/main/challenges/bound5.md
//

@testable import Exhaust

/// 5-tuple of `Int16` lists where each list sums to less than 256, but the total can overflow `5 × 256`. The challenge property fails on overflow; the minimal counterexample has two non-empty lists.
enum Bound5Fixture {
    struct Tuple: Equatable {
        let a: [Int16]
        let b: [Int16]
        let c: [Int16]
        let d: [Int16]
        let e: [Int16]
        let arr: [Int16]

        init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
            self.a = a
            self.b = b
            self.c = c
            self.d = d
            self.e = e
            arr = a + b + c + d + e
        }
    }

    /// Generator: each component is a length 0–10 array of `Int16` filtered so each list sums to less than 256.
    static let gen: ReflectiveGenerator<Tuple> = {
        let arr = #gen(.int16(scaling: .constant).array(length: 0 ... 10, scaling: .constant))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return #gen(arr, arr, arr, arr, arr) { a, b, c, d, e in
            Tuple(a: a, b: b, c: c, d: d, e: e)
        }
    }()

    /// Property: the sum of all values across the five lists is less than `5 × 256`. False because of `Int16` wraparound.
    @Sendable
    static func property(_ tuple: Tuple) -> Bool {
        if tuple.arr.isEmpty { return true }
        return tuple.arr.dropFirst().reduce(tuple.arr[0], &+) < 5 * 256
    }
}
