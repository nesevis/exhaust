////
////  ShrinkingTerminationTests.swift
////  ExhaustTests
////
////  Tests to ensure shrinking operations always terminate in finite steps
////  and produce progressively smaller values.
////
//
// import Testing
// @testable import Exhaust
@_spi(ExhaustInternal) @testable import ExhaustCore
//
// @Suite("Shrinking Termination Laws")
// struct ShrinkingTerminationTests {
//
//    @Test("Shrinking always terminates for integers")
//    func testIntegerShrinkingTermination() throws {
//        let gen = Int.arbitrary
//
//        let largeValue = 50000
//        var stepCount = 0
//        let maxSteps = 1000 // Safety limit
//
//        // Property that always fails to force maximum shrinking
//        let property: (Int) -> Bool = { _ in false }
//
//        let shrunken = try Interpreters.shrink(largeValue, using: gen, where: property)
//
//        // Should reach the minimal value (0 for integers)
//        #expect(shrunken == 0)
//    }
//
//    @Test("Shrinking terminates for arrays")
//    func testArrayShrinkingTermination() throws {
//        let gen = Int.arbitrary.proliferate(with: 1...50)
//
//        let largeArray = Array(1...30)
//
//        // Property that always fails
//        let property: ([Int]) -> Bool = { _ in false }
//
//        let shrunken = try Interpreters.shrink(largeArray, using: gen, where: property)
//
//        // Should shrink to minimal failing case
//        #expect(shrunken.count <= largeArray.count)
//    }
//
//    @Test("Shrinking produces progressively smaller values")
//    func testShrinkingMonotonicity() throws{
//        let gen = UInt.arbitrary
//
//        let startValue: UInt = 1000
//
//        // Property that fails for values > 10
//        let property: (UInt) -> Bool = { $0 <= 10 }
//
//        let shrunken = try Interpreters.shrink(startValue, using: gen, where: property)
//
//        // Shrunk value should be closer to boundary
//        #expect(shrunken > 10) // Still fails the property
//        #expect(shrunken < startValue) // But smaller than original
//    }
//
//    @Test("String shrinking terminates")
//    func testStringShrinkingTermination() throws {
//        let gen = String.arbitrary
//
//        let longString = String(repeating: "x", count: 100)
//
//        // Property that fails for strings with length > 5
//        let property: (String) -> Bool = { $0.count <= 5 }
//
//        let shrunken = try Interpreters.shrink(longString, using: gen, where: property)
//
//        // Should produce a smaller failing string
//        #expect(shrunken.count > 5) // Still fails
//        #expect(shrunken.count < longString.count) // But shorter
//    }
//
//    @Test("Nested structure shrinking terminates")
//    func testNestedStructureShrinkingTermination() throws {
//        struct Container: Equatable {
//            let items: [[String]]
//        }
//
//        let gen = Gen.lens(
//            extract: \Container.items,
//            String.arbitrary.proliferate(with: 1...5).proliferate(with: 1...3)
//        ).map { Container(items: $0) }
//
//
//        let complex = Container(items: [
//            ["a", "b", "c", "d"],
//            ["e", "f", "g"],
//            ["h", "i"]
//        ])
//
//        // Property that fails for total item count > 2
//        let property: (Container) -> Bool = { container in
//            let totalItems = container.items.flatMap { $0 }.count
//            return totalItems <= 2
//        }
//
//        let shrunken = try Interpreters.shrink(complex, using: gen, where: property)
//        let originalTotal = complex.items.flatMap { $0 }.count
//        let shrunkenTotal = shrunken.items.flatMap { $0 }.count
//
//        #expect(shrunkenTotal > 2) // Still fails property
//        #expect(shrunkenTotal <= originalTotal) // Not larger than original
//    }
//
//    @Test("Shrinking converges to minimal counterexample")
//    func testShrinkingConvergence() throws {
//        let gen = Gen.choose(in: 1...1000, input: Any.self)
//
//        let value = 500
//
//        // Property fails for values > 100
//        let property: (Int) -> Bool = { $0 <= 100 }
//
//        let shrunken = try Interpreters.shrink(value, using: gen, where: property)
//
//        // Should converge to the boundary value
//        #expect(shrunken == 101)
//    }
//
//    @Test("Tuple shrinking terminates")
//    func testTupleShrinkingTermination() throws {
//        let gen = Gen.zip(UInt.arbitrary, String.arbitrary)
//
//        let tuple: (UInt, String) = (500, "hello world")
//
//        // Property fails when number > 10 OR string length > 3
//        let property: (UInt, String) -> Bool = { num, str in
//            num <= 10 && str.count <= 3
//        }
//
//        let shrunken = try Interpreters.shrink(tuple, using: gen, where: property)
//
//        // Should shrink both components
//        #expect(shrunken.0 <= tuple.0 || shrunken.1.count <= tuple.1.count)
//    }
// }
