//
//  ReflectReplacingZipComponentTests.swift
//  ExhaustTests
//
//  Tests the component-replacing reflection primitive behind the comparison-injection field graft: swap one field of an initializer-shaped generator's value, reflect the whole composite, and confirm the reflected sequence materializes to the retargeted value.
//

import Exhaust
import ExhaustCore
import Testing

@Suite("Reflect Replacing Zip Component")
struct ReflectReplacingZipComponentTests {
    @Test("Grafts a field and preserves the rest")
    func graftsFieldPreservingRest() throws {
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let parent = GraftPoint(x: 42, y: 99)

        let tree = try #require(
            try Interpreters.reflectReplacingZipComponent(gen.gen, parent: parent, index: 0) { _ in 7 }
        )
        #expect(try materialize(gen, tree) == GraftPoint(x: 7, y: 99))
    }

    @Test("Grafts the second field")
    func graftsSecondField() throws {
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let parent = GraftPoint(x: 42, y: 99)

        let tree = try #require(
            try Interpreters.reflectReplacingZipComponent(gen.gen, parent: parent, index: 1) { _ in 7 }
        )
        #expect(try materialize(gen, tree) == GraftPoint(x: 42, y: 7))
    }

    @Test("Grafts a comparison operand into a field, reconstructing via the field's runtime type")
    func graftsOperandIntoField() throws {
        // The literal operand word stands in for the trace-cmp comparand the pool would supply.
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let parent = GraftPoint(x: 1, y: 2)
        let target = 123_456_789
        let operand = UInt64(bitPattern: Int64(target))

        let tree = try #require(
            try Interpreters.reflectGraftingOperand(into: gen.gen, parent: parent, index: 0, operand: operand)
        )
        #expect(try materialize(gen, tree) == GraftPoint(x: target, y: 2))

        let second = try #require(
            try Interpreters.reflectGraftingOperand(into: gen.gen, parent: parent, index: 1, operand: operand)
        )
        #expect(try materialize(gen, second) == GraftPoint(x: 1, y: target))
    }

    @Test("Grafting an out-of-range field index is a miss")
    func graftingOutOfRangeIndexIsNil() throws {
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let result = try Interpreters.reflectGraftingOperand(
            into: gen.gen,
            parent: GraftPoint(x: 1, y: 2),
            index: 5,
            operand: 99
        )
        #expect(result == nil)
    }

    @Test("Out-of-range index is a miss")
    func outOfRangeIndexIsNil() throws {
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let result = try Interpreters.reflectReplacingZipComponent(
            gen.gen,
            parent: GraftPoint(x: 1, y: 2),
            index: 5
        ) { _ in 7 }
        #expect(result == nil)
    }

    @Test("A rejected replacement is a miss")
    func rejectedReplacementIsNil() throws {
        let gen = #gen(.int(in: 0 ... Int.max), .int(in: 0 ... Int.max)) { x, y in
            GraftPoint(x: x, y: y)
        }
        let result = try Interpreters.reflectReplacingZipComponent(
            gen.gen,
            parent: GraftPoint(x: 1, y: 2),
            index: 0
        ) { _ in nil }
        #expect(result == nil)
    }

    @Test("A non-zip generator is a miss")
    func nonZipGeneratorIsNil() throws {
        let gen = #gen(.int(in: 0 ... Int.max))
        let result = try Interpreters.reflectReplacingZipComponent(gen.gen, parent: 10, index: 0) { _ in 7 }
        #expect(result == nil)
    }
}

// MARK: - Helpers

private struct GraftPoint: Equatable {
    let x: Int
    let y: Int
}

private func materialize<Output: Equatable>(
    _ gen: ReflectiveGenerator<Output>,
    _ tree: ChoiceTree
) throws -> Output {
    let sequence = ChoiceSequence.flatten(tree)
    guard case let .success(value, _, _) = Materializer.materialize(
        gen.gen,
        prefix: sequence,
        mode: .exact,
        fallbackTree: tree
    ),
        let typed = value as? Output
    else {
        throw MaterializeFailure.failed
    }
    return typed
}

private enum MaterializeFailure: Error {
    case failed
}
