import Foundation
import Testing
@testable import Exhaust
@testable import ExhaustCore

// MARK: - PrincipledScheduler Parity Tests

/// Validates that the ``PrincipledScheduler`` produces reduction quality equal to or better than the V-cycle ``ReductionScheduler`` on every shrinking challenge generator.
@Suite("PrincipledScheduler Parity")
struct PrincipledSchedulerParityTests {
    private static let vCycleConfig = Interpreters.BonsaiReducerConfiguration(
        from: .fast, scheduler: .vCycle
    )
    private static let principledConfig = Interpreters.BonsaiReducerConfiguration(
        from: .fast, scheduler: .principled
    )

    // MARK: - Length List

    @Test("LengthList parity", arguments: [
        UInt64(42), UInt64(7777), UInt64(31415),
    ])
    func lengthListParity(seed: UInt64) throws {
        let gen: ReflectiveGenerator<[UInt]> = #gen(.uint(in: 0 ... 1000)).array(length: 1 ... 100)

        let property: ([UInt]) -> Bool = { arr in
            arr.max() ?? 0 < 900
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        // Both must find the optimal counterexample.
        #expect(vResult.1 == [900])
        #expect(pResult.1 == [900])

        // Principled shortlex must be <= V-cycle shortlex.
        #expect(
            pResult.0.count <= vResult.0.count
                || pResult.0.shortLexPrecedes(vResult.0)
                || pResult.0 == vResult.0,
            "Principled sequence should be shortlex ≤ V-cycle"
        )
    }

    // MARK: - Coupling

    @Test("Coupling parity", arguments: [
        UInt64(42), UInt64(999), UInt64(54321),
    ])
    func couplingParity(seed: UInt64) throws {
        let gen = #gen(.int(in: 0 ... 10))
            .bind { n in
                #gen(.int(in: 0 ... n)).array(length: 2 ... max(2, n + 1))
            }
            .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

        let property: ([Int]) -> Bool = { arr in
            arr.indices.allSatisfy { index in
                let value = arr[index]
                if value != index, arr[value] == index {
                    return false
                }
                return true
            }
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        // Both must find the optimal counterexample.
        #expect(vResult.1 == [1, 0])
        #expect(pResult.1 == [1, 0])
    }

    // MARK: - Reverse

    @Test("Reverse parity", arguments: [
        UInt64(42), UInt64(7777), UInt64(31415),
    ])
    func reverseParity(seed: UInt64) throws {
        let gen = #gen(.uint()).array(length: 1 ... 1000)

        let property: ([UInt]) -> Bool = { arr in
            arr.elementsEqual(arr.reversed())
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        var vConfig = Self.vCycleConfig
        vConfig.humanOrderPostProcess = true
        var pConfig = Self.principledConfig
        pConfig.humanOrderPostProcess = true

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: vConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: pConfig, property: property
            )
        )

        // Both must find the optimal counterexample.
        #expect(vResult.1 == [0, 1])
        #expect(pResult.1 == [0, 1])
    }

    // MARK: - Difference

    @Test("Difference must not be zero parity", arguments: [
        [700, 700], [500, 500], [100, 100],
    ] as [[Int]])
    func differenceMustNotBeZeroParity(value: [Int]) throws {
        let gen = #gen(.int(in: 1 ... 1000)).array(length: 2)

        let property: ([Int]) -> Bool = { arr in
            arr[0] < 10 || arr[0] != arr[1]
        }

        let tree = try #require(
            try Interpreters.reflect(gen, with: value)
        )

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        #expect(vResult.1 == [10, 10])
        #expect(pResult.1 == [10, 10])
    }

    // MARK: - Nested Lists

    @Test("NestedLists parity", arguments: [
        UInt64(42), UInt64(7777), UInt64(31415),
    ])
    func nestedListsParity(seed: UInt64) throws {
        let gen = #gen(.uint().array().array())

        let property: ([[UInt]]) -> Bool = { arr in
            arr.map(\.count).reduce(0, +) <= 10
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        // Both must find a single array of 11 zeros.
        let expectedNestedLists: [[UInt]] = [Array(repeating: UInt(0), count: 11)]
        #expect(vResult.1 == expectedNestedLists)
        #expect(pResult.1 == expectedNestedLists)
    }

    // MARK: - Bound5

    @Test("Bound5 parity", arguments: [
        Bound5(
            a: [-18914, -2906, 9816],
            b: [7672, 16087, 24512],
            c: [-11812, -5368, 8526, -24292, 21020, 14344, -1893, -22885],
            d: [25982, 8828, 5007, -6389],
            e: [12744, -11152, -18025, -29069, 30825]
        ),
        Bound5(
            a: [-10709],
            b: [29251, 31661],
            c: [-18678],
            d: [-2824, 15387, -15932, -23458, -6124, 3327, -21001, 16059, -21211, -27710],
            e: [16775, -32275, 813, 11044]
        ),
        Bound5(
            a: [10607, 11752, -7272, -15733],
            b: [],
            c: [14063, -27312, 2705],
            d: [-4862, 11017, 12831, 19004],
            e: [-25748, 8284, -13626, 12773, 4040]
        ),
    ])
    func bound5Parity(value: Bound5) throws {
        let gen = Self.bound5Gen

        let property: (Bound5) -> Bool = { bound5 in
            if bound5.arr.isEmpty {
                return true
            }
            return bound5.arr.dropFirst().reduce(bound5.arr[0], &+) < 5 * 256
        }

        let tree = try #require(
            try Interpreters.reflect(gen, with: value)
        )

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        // Both must reach the optimal: two-element array with sorted values [-32768, -1].
        #expect(vResult.1.arr.count == 2)
        #expect(vResult.1.arr.sorted() == [-32768, -1])
        #expect(pResult.1.arr.count == 2)
        #expect(pResult.1.arr.sorted() == [-32768, -1])
    }

    // MARK: - Deletion

    @Test("Deletion parity", arguments: [
        UInt64(42), UInt64(123), UInt64(7777),
    ])
    func deletionParity(seed: UInt64) throws {
        let numberGen = #gen(.int(in: 0 ... 20))
        let gen = #gen(numberGen.array(length: 2 ... 20), numberGen)
            .filter { $0.contains($1) }

        let property: (([Int], Int)) -> Bool = { pair in
            var list = pair.0
            let element = pair.1
            guard let index = list.firstIndex(of: element) else {
                return true
            }
            list.remove(at: index)
            return list.contains(element) == false
        }

        let (tree, _) = try findFailingTree(gen: gen, seed: seed, property: property)

        let vResult = try #require(
            try ReductionScheduler.run(
                gen: gen, initialTree: tree, config: Self.vCycleConfig, property: property
            )
        )
        let pResult = try #require(
            try PrincipledScheduler.run(
                gen: gen, initialTree: tree, config: Self.principledConfig, property: property
            )
        )

        // Both must find the optimal counterexample.
        #expect(vResult.1.0 == [0, 0])
        #expect(vResult.1.1 == 0)
        #expect(pResult.1.0 == [0, 0])
        #expect(pResult.1.1 == 0)
    }
}

// MARK: - Bound5 Generator

extension PrincipledSchedulerParityTests {
    fileprivate static let bound5Gen: ReflectiveGenerator<Bound5> = {
        let arr = #gen(.int16(scaling: .constant).array(length: 0 ... 10, scaling: .constant))
            .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
        return #gen(arr, arr, arr, arr, arr) { a, b, c, d, e in
            Bound5(a: a, b: b, c: c, d: d, e: e)
        }
    }()
}

// MARK: - Types

extension PrincipledSchedulerParityTests {
    struct Bound5: Equatable, Sendable, CustomTestStringConvertible {
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

        var testDescription: String {
            "Bound5(a: \(a), b: \(b), c: \(c), d: \(d), e: \(e))"
        }
    }
}

// MARK: - Helpers

/// Finds the first failing tree for a generator with a given property.
private func findFailingTree<Output>(
    gen: ReflectiveGenerator<Output>,
    seed: UInt64,
    property: @escaping (Output) -> Bool
) throws -> (ChoiceTree, Output) {
    var iterator = ValueAndChoiceTreeInterpreter(gen, materializePicks: true, seed: seed)
    for _ in 0 ..< 500 {
        guard let (value, tree) = try iterator.next() else { continue }
        if property(value) == false {
            return (tree, value)
        }
    }
    throw ParityTestError.noFailingInput
}

private enum ParityTestError: Error, CustomStringConvertible {
    case noFailingInput

    var description: String {
        "Could not find a failing input within 500 iterations"
    }
}
