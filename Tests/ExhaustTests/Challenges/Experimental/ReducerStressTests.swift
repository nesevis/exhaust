//
//  ReducerStressTests.swift
//  Exhaust
//

import ExhaustTestSupport
import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustCore

@Suite("Reducer Stress Tests", .tags(.challenge, .slow))
struct ReducerStressTests {
    // Generators that produce large, structurally complex counterexamples
    // to stress the rebuild and source construction paths. Uses `reflecting:`
    // to seed reduction from a known worst case. Bind-based generators use
    // `.bound(forward:backward:)` so the backward pass can decompose the
    // output back through the bind.

    // MARK: - Wide Flat Sequence

    @Test("Wide flat sequence — 5000 elements")
    func wideFlatSequence() {
        let gen = #gen(.int(in: 0 ... 10000).array(length: 0 ... 5000))
        let value = Array(0 ..< 5000)

        let output = #exhaust(
            gen,
            reflecting: value,
            .suppress(.issueReporting)
        ) { arr in
            arr.count < 10 || arr.reduce(0, +) < 100
        }
        #expect(output != nil)
        #expect((output?.count ?? 0) <= 15)
    }

    // MARK: - Deeply Nested Sequences

    @Test("Deeply nested sequences — 5 x 10 x 10 array")
    func deeplyNestedSequences() {
        let gen = #gen(.int(in: 0 ... 50).array(length: 0 ... 10).array(length: 0 ... 10).array(length: 0 ... 5))
        let value: [[[Int]]] = (0 ..< 5).map { _ in
            (0 ..< 10).map { _ in
                Array(repeating: 25, count: 10)
            }
        }

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { outer in
            let flat = outer.flatMap(\.self).flatMap(\.self)
            return flat.count < 10 || flat.reduce(0, +) < 100
        }
        #expect(output != nil)
    }

    // MARK: - Fixed-Length Wide Array

    @Test("Fixed-length wide array — 5000 elements, pure value reduction")
    func fixedLengthWideArray() {
        let gen = #gen(.int(in: -10000 ... 10000).array(length: 5000 ... 5000))
        let value = (0 ..< 5000).map { $0 * 4 - 10000 }

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { arr in
            arr.count(where: { $0 > 0 }) < 3 || arr.reduce(0, +) == 0
        }
        #expect(output != nil)
    }

    // MARK: - Many Small Sequences

    @Test("Many small sequences — 100 arrays of 0-4 elements")
    func manySmallSequences() {
        let gen = #gen(.int(in: 0 ... 100).array(length: 0 ... 4).array(length: 100 ... 100))
        let value = Array(repeating: [10, 20, 30, 40], count: 100)

        let output = #exhaust(
            gen,
            reflecting: value,
            .suppress(.issueReporting)
        ) { arrays in
            let totalElements = arrays.reduce(0) { $0 + $1.count }
            let totalSum = arrays.flatMap(\.self).reduce(0, +)
            return totalElements < 20 || totalSum < 200
        }
        #expect(output != nil)
    }

    // MARK: - Wide Coupled Arrays (bidirectional bind)

    struct CoupledArrays {
        let size: Int
        let arrays: [[Int]]
    }

    @Test("Wide coupled arrays — bound fans out to 5 dependent arrays")
    func wideCoupledArrays() {
        let gen = #gen(.int(in: 1 ... 30)).bound(
            forward: { size in
                #gen(.int(in: 0 ... size).array(length: 0 ... max(1, size)).array(length: 5 ... 5))
                    .mapped(
                        forward: { CoupledArrays(size: size, arrays: $0) },
                        backward: { $0.arrays }
                    )
            },
            backward: { (output: CoupledArrays) in output.size }
        )

        let value = CoupledArrays(size: 25, arrays: Array(repeating: Array(0 ..< 25), count: 5))

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { coupled in
            let totalElements = coupled.arrays.reduce(0) { $0 + $1.count }
            return totalElements < 8 || coupled.arrays.allSatisfy { $0.max() ?? 0 < 3 }
        }
        #expect(output != nil)
    }

    // MARK: - Nested Bind Cascade (bidirectional bind)

    struct BindCascadeOutput {
        let outerLength: Int
        let innerArray: [Int]
    }

    @Test("Nested bind cascade — controlling length determines dependent array")
    func nestedBindCascade() {
        let gen = #gen(.int(in: 3 ... 40)).bound(
            forward: { outerLength in
                #gen(.int(in: 0 ... 50).array(length: max(1, outerLength) ... max(1, outerLength)))
                    .mapped(
                        forward: { BindCascadeOutput(outerLength: outerLength, innerArray: $0) },
                        backward: { $0.innerArray }
                    )
            },
            backward: { (output: BindCascadeOutput) in output.outerLength }
        )

        let value = BindCascadeOutput(outerLength: 35, innerArray: Array(repeating: 25, count: 35))

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { result in
            result.innerArray.count < 3 || result.innerArray.reduce(0, +) < 5
        }
        #expect(output != nil)
    }

    // MARK: - Large Compound Elements

    @Test("Large sequence of compound elements — 80 triples")
    func largeSequenceOfCompounds() {
        let tripleGen = #gen(.int(in: -100 ... 100), .int(in: -200 ... 200), .int(in: -300 ... 300))
        let gen = tripleGen.array(length: 0 ... 100)
        let value = (0 ..< 80).map { i in (i, i * 2, i * 3) }

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { arr in
            arr.count < 5 || arr.reduce(0) { $0 + abs($1.0) + abs($1.1) + abs($1.2) } < 50
        }
        #expect(output != nil)
        #expect((output?.count ?? 0) <= 10)
    }

    // MARK: - Size-Dependent Sequence (bidirectional bind)

    struct SizedSequence {
        let size: Int
        let elements: [Int]
    }

    @Test("Size-dependent sequence — 200 elements controlled by bind-inner")
    func sizeDependentSequence() {
        let gen = #gen(.int(in: 10 ... 200)).bound(
            forward: { size in
                #gen(.int(in: 0 ... size).array(length: size ... size))
                    .mapped(
                        forward: { SizedSequence(size: size, elements: $0) },
                        backward: { $0.elements }
                    )
            },
            backward: { (output: SizedSequence) in output.size }
        )

        let value = SizedSequence(size: 200, elements: Array(0 ..< 200))

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { result in
            result.elements.count < 15 || result.elements.reduce(0, +) < 50
        }
        #expect(output != nil)
    }

    // MARK: - One-At-A-Time Deletion

    @Test("One-at-a-time deletion — 300 elements, pairwise consecutive")
    func oneAtATimeDeletion() {
        // The property requires every adjacent pair to differ by exactly 1.
        // The initial value is [0, 1, 2, ..., 299]. Deleting any element
        // from the middle creates a gap (for example, removing 5 makes the
        // sequence jump from 4 to 6), which violates the property. Only
        // single-element deletion from the head or tail preserves the
        // invariant. Batch deletions of 2+ consecutive elements always
        // create a gap, forcing the reducer to delete one element at a time.
        let gen = #gen(.int(in: 0 ... 500).array(length: 0 ... 300))
        let value = Array(0 ..< 300)

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { arr in
            guard arr.count >= 10 else { return true }
            for index in arr.indices.dropLast() {
                guard arr[index + 1] - arr[index] == 1 else { return true }
            }
            return false
        }
        #expect(output != nil)
        #expect(output?.count == 10)
    }

    @Test("One-at-a-time deletion — 5000 elements")
    func oneAtATimeDeletionLarge() {
        let gen = #gen(.int(in: 0 ... 10000).array(length: 0 ... 5000))
        let value = Array(0 ..< 5000)

        let output = #exhaust(gen, reflecting: value, .suppress(.issueReporting)) { arr in
            guard arr.count >= 10 else { return true }
            for index in arr.indices.dropLast() {
                guard arr[index + 1] - arr[index] == 1 else { return true }
            }
            return false
        }
        #expect(output != nil)
        #expect(output?.count == 10)
    }
}
