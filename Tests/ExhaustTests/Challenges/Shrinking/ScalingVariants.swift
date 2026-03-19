//
//  ScalingVariants.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/3/2026.
//

import Foundation
import Testing
@testable import Exhaust

// MARK: - Bound5

@Suite("Bound5 Scaling Variants")
struct Bound5ScalingVariant {
    typealias Bound5 = Bound5ShrinkingChallenge.Bound5

    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func bound5(variant: ScalingVariant) {
        let int16Scaling: SizeScaling<Int16> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let arr = #gen(.int16(scaling: int16Scaling).array(length: 0 ... 10, scaling: arrayScaling))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        let gen = #gen(arr, arr, arr, arr, arr) { a, b, c, d, e in
            Bound5(a: a, b: b, c: c, d: d, e: e)
        }

        let value = Bound5(
            a: [-18914, -2906, 9816],
            b: [7672, 16087, 24512],
            c: [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885],
            d: [25982, 8828, 5007, -6389],
            e: [12744, -11152, -18025, -29069, 30825]
        )

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value)
        ) { b5 in
            if b5.arr.isEmpty {
                return true
            }
            return b5.arr.dropFirst().reduce(b5.arr[0], &+) < 5 * 256
        }

        #expect(output?.arr.count == 2)
        #expect(output?.arr.sorted() == [-32768, -1])
    }
}

// MARK: - Binary Heap

@Suite("Binary Heap Scaling Variants")
struct BinaryHeapScalingVariant {
    typealias Heap = BinaryHeapShrinkingChallenge.Heap<Int>

    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func binaryHeap(variant: ScalingVariant) throws {
        let scaling: SizeScaling<Int> = variant.scaling()
        let gen = Self.heapGen(depth: 6, scaling: scaling)

        let property: @Sendable (Heap) -> Bool = { heap in
            guard BinaryHeapShrinkingChallenge.invariant(heap) else { return true }
            let xs = BinaryHeapShrinkingChallenge.toSortedList(heap)
            let sorted = BinaryHeapShrinkingChallenge.toList(heap).sorted()
            return sorted == xs.sorted() && xs == xs.sorted()
        }

        let output = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting,
                property: property
            )
        )
        let outputValues = BinaryHeapShrinkingChallenge.toList(output).sorted()
        #expect(Set(outputValues) == [0, 1])
    }

    // MARK: - Recursive generator

    static func heapGen(min: Int = 0, depth: UInt64, scaling: SizeScaling<Int>) -> ReflectiveGenerator<Heap> {
        let maxVal = 100
        let emptyGen: ReflectiveGenerator<Heap> = #gen(.just(.empty))

        guard depth > 0, min <= maxVal else {
            return emptyGen
        }

        let nodeGen = #gen(.int(in: min ... maxVal, scaling: scaling))
            .bind { value in
                #gen(
                    heapGen(min: value, depth: depth / 2, scaling: scaling),
                    heapGen(min: value, depth: depth / 2, scaling: scaling)
                )
                .mapped(
                    forward: { left, right in Heap.node(value, left, right) },
                    backward: { heap in
                        switch heap {
                        case let .node(_, left, right): (left, right)
                        case .empty: (.empty, .empty)
                        }
                    }
                )
            }

        return #gen(.oneOf(weighted:
            (1, emptyGen),
            (7, nodeGen)))
    }
}

// MARK: - Calculator

@Suite("Calculator Scaling Variants")
struct CalculatorScalingVariant {
    typealias Expr = CalculatorShrinkingChallenge.Expr

    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func calculator(variant: ScalingVariant) {
        let scaling: SizeScaling<Int> = variant.scaling()
        let gen = #gen(Self.expression(depth: 4, scaling: scaling))

        let result = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(Expr.div(.value(5), .add(.value(3), .value(-3))))
        ) { expr in
            guard CalculatorShrinkingChallenge.containsLiteralDivisionByZero(expr) == false else {
                return true
            }
            do {
                _ = try CalculatorShrinkingChallenge.eval(expr)
                return true
            } catch CalculatorShrinkingChallenge.EvalError.divisionByZero {
                return false
            } catch {
                return false
            }
        }

        #expect(
            result == .div(.value(0), .div(.value(0), .value(1))) ||
                result == .div(.value(0), .div(.value(0), .value(-1))) ||
                result == .div(.value(0), .add(.value(0), .value(0)))
        )
    }

    // MARK: - Recursive generator

    static func expression(depth: UInt64, scaling: SizeScaling<Int>) -> ReflectiveGenerator<Expr> {
        let leaf = #gen(.int(in: -10 ... 10, scaling: scaling))
            .mapped(forward: { Expr.value($0) }, backward: { $0.value ?? 0 })

        guard depth > 0 else {
            return leaf
        }

        let child = expression(depth: depth - 1, scaling: scaling)

        let add = #gen(child, leaf)
            .mapped(
                forward: { lhs, rhs in Expr.add(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )
        let div = #gen(leaf, child)
            .mapped(
                forward: { lhs, rhs in Expr.div(lhs, rhs) },
                backward: { value in
                    switch value {
                    case let .add(lhs, rhs): (lhs, rhs)
                    case let .div(lhs, rhs): (lhs, rhs)
                    case .value:
                        (value, value)
                    }
                }
            )

        return #gen(.oneOf(weighted:
            (3, leaf),
            (3, add),
            (3, div)))
    }
}

// MARK: - Coupling

@Suite("Coupling Scaling Variants")
struct CouplingScalingVariant {
    @Test("Scaling variant", arguments: [ScalingVariant.constant])
    func coupling(variant: ScalingVariant) throws {
        ExhaustLog.setConfiguration(.init(isEnabled: true, minimumLevel: .info, categoryMinimumLevels: [.reducer: .debug], format: .human))
        let intScaling: SizeScaling<Int> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let gen = #gen(.int(in: 0 ... 100, scaling: intScaling))
            .bind { n in
                #gen(.int(in: 0 ... n, scaling: intScaling)).array(length: 2 ... max(2, n + 1), scaling: arrayScaling)
            }
            .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

        let value = try #require(
            #exhaust(
                gen,
                .suppressIssueReporting,
                .replay(9293532994034525134)
            ) { arr in
                arr.indices.allSatisfy { i in
                    let j = arr[i]
                    if j != i, arr[j] == i {
                        return false
                    }
                    return true
                }
            }
        )

        #expect(value.count == 2)
        #expect(value == [1, 0])
    }
}

// MARK: - Deletion

@Suite("Deletion Scaling Variants")
struct DeletionScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func deletion(variant: ScalingVariant) {
        let intScaling: SizeScaling<Int> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let numberGen = #gen(.int(in: 0 ... 20, scaling: intScaling))
        let gen = #gen(numberGen.array(length: 2 ... 20, scaling: arrayScaling), numberGen)
            .filter { $0.contains($1) }

        let property: @Sendable ([Int], Int) -> Bool = { xs, x in
            var xs = xs
            guard let index = xs.firstIndex(of: x) else {
                return true
            }
            xs.remove(at: index)
            return xs.contains(x) == false
        }

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(([5, 3, 5, 7], 5)),
            property: property
        )

        #expect(output?.0 == [0, 0])
        #expect(output?.1 == 0)
    }
}

// MARK: - Difference

@Suite("Difference Scaling Variants")
struct DifferenceScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func difference(variant: ScalingVariant) {
        let intScaling: SizeScaling<Int> = variant.scaling()
        let gen = #gen(.int(in: 1 ... 1000, scaling: intScaling)).array(length: 2)

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting([700, 700])
        ) { arr in
            arr[0] < 10 || arr[0] != arr[1]
        }

        #expect(output == [10, 10])
    }
}

// MARK: - Distinct

@Suite("Distinct Scaling Variants")
struct DistinctScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func distinct(variant: ScalingVariant) {
        let intScaling: SizeScaling<Int> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let gen = #gen(.int(scaling: intScaling).array(length: 3 ... 30, scaling: arrayScaling))

        let counterExample = #exhaust(
            gen,
            .suppressIssueReporting,
            .humanOrderPostProcess,
            .reflecting([1337, 80085, 69, 67])
        ) {
            Set($0).count < 3
        }

        #expect(counterExample == [-1, 0, 1])
    }
}

// MARK: - Large Union List

@Suite("Large Union List Scaling Variants")
struct LargeUnionListScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func largeUnionList(variant: ScalingVariant) {
        let intScaling: SizeScaling<Int> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let gen = #gen(.int(scaling: intScaling).array(length: 1 ... 10, scaling: arrayScaling).array(length: 1 ... 10, scaling: arrayScaling))

        let value = [[76132], [-61180, -48610, 71763], [-25593]]

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .humanOrderPostProcess
        ) { arr in
            Set(arr.flatMap(\.self)).count <= 4
        }

        #expect(output?.flatMap(\.self) == [-2, -1, 0, 1, 2])
    }
}

// MARK: - Nested Lists

@Suite("Nested Lists Scaling Variants")
struct NestedListsScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func nestedLists(variant: ScalingVariant) {
        let uintScaling: SizeScaling<UInt> = variant.scaling()

        let gen = #gen(.uint(scaling: uintScaling).array().array())

        let value: [[UInt]] = [[1, 2, 3, 4, 5, 6], [7, 8, 9, 10, 11]]

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value)
        ) { arr in
            arr.map(\.count).reduce(0, +) <= 10
        }

        #expect(output == [Array(repeating: UInt(0), count: 11)])
    }
}

// MARK: - Reverse

@Suite("Reverse Scaling Variants")
struct ReverseScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func reverse(variant: ScalingVariant) {
        let uintScaling: SizeScaling<UInt> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let gen = #gen(.uint(scaling: uintScaling)).array(length: 1 ... 1000, scaling: arrayScaling)

        let value: [UInt] = [5, 3, 1, 4, 2]

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value),
            .humanOrderPostProcess
        ) { arr in
            arr.elementsEqual(arr.reversed())
        }

        #expect(output == [0, 1])
    }
}

// MARK: - Length List

@Suite("Length List Scaling Variants")
struct LengthListScalingVariant {
    @Test("Scaling variant", arguments: ScalingVariant.allCases)
    func lengthList(variant: ScalingVariant) {
        let uintScaling: SizeScaling<UInt> = variant.scaling()
        let arrayScaling: SizeScaling<UInt64> = variant.scaling()

        let gen: ReflectiveGenerator<[UInt]> = #gen(.uint(in: 0 ... 1000, scaling: uintScaling)).array(length: 1 ... 100, scaling: arrayScaling)

        let value: [UInt] = [100, 200, 900, 50, 300]

        let output = #exhaust(
            gen,
            .suppressIssueReporting,
            .reflecting(value)
        ) { arr in
            arr.max() ?? 0 < 900
        }

        #expect(output == [900])
    }
}

// MARK: - ScalingVariant

enum ScalingVariant: String, CaseIterable, CustomTestStringConvertible {
    case constant
    case linear
    case linearFromOrigin
    case exponential
    case exponentialFromOrigin

    var testDescription: String { rawValue }

    func scaling<Bound: FixedWidthInteger & Sendable>(origin: Bound = 0) -> SizeScaling<Bound> {
        switch self {
        case .constant: .constant
        case .linear: .linear
        case .linearFromOrigin: .linearFrom(origin: origin)
        case .exponential: .exponential
        case .exponentialFromOrigin: .exponentialFrom(origin: origin)
        }
    }
}
