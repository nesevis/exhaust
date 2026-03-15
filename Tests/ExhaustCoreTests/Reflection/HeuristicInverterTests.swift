//
//  HeuristicInverterTests.swift
//  ExhaustTests
//

import Testing
@testable import ExhaustCore

@Suite("HeuristicInverter")
struct HeuristicInverterTests {
    // MARK: - inverter()

    @Test("Same type returns identity inverter")
    func sameTypeIdentity() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Int", outputType: "Int"))
        let result = try invert(42)
        #expect(result as? Int == 42)
    }

    @Test("Int → Double round-trip succeeds")
    func intToDouble() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Int", outputType: "Double"))
        let result = try invert(42.0 as Double)
        #expect(result as? Int == 42)
    }

    @Test("Double → Int succeeds for integral values")
    func doubleToIntIntegral() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Double", outputType: "Int"))
        let result = try invert(7 as Int)
        #expect(result as? Double == 7.0)
    }

    @Test("Double → Int fails for non-integral values (lossy)")
    func doubleToIntLossy() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Int", outputType: "Double"))
        // 3.7 can't round-trip through Int — Int(exactly: 3.7) returns nil → throws
        #expect(throws: HeuristicInverter.InversionError.self) {
            _ = try invert(3.7 as Double)
        }
    }

    @Test("UInt64 → Int64 succeeds for values in range")
    func uint64ToInt64() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "UInt64", outputType: "Int64"))
        let result = try invert(100 as Int64)
        #expect(result as? UInt64 == 100)
    }

    @Test("Int8 → UInt8 succeeds for non-negative values")
    func int8ToUint8() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Int8", outputType: "UInt8"))
        let result = try invert(50 as UInt8)
        #expect(result as? Int8 == 50)
    }

    @Test("String → Int returns nil (unsupported)")
    func stringToIntUnsupported() {
        let inverter = HeuristicInverter.inverter(inputType: "String", outputType: "Int")
        #expect(inverter == nil)
    }

    @Test("Int → String returns nil (unsupported)")
    func intToStringUnsupported() {
        let inverter = HeuristicInverter.inverter(inputType: "Int", outputType: "String")
        #expect(inverter == nil)
    }

    @Test("Float → Double round-trip")
    func floatToDouble() throws {
        let invert = try #require(HeuristicInverter.inverter(inputType: "Float", outputType: "Double"))
        let result = try invert(1.5 as Double)
        #expect(result as? Float == 1.5)
    }

    // MARK: - areEquivalent()

    @Test("Numeric equivalence across types")
    func numericEquivalence() {
        #expect(HeuristicInverter.areEquivalent(42 as Int, 42.0 as Double))
        #expect(HeuristicInverter.areEquivalent(7 as UInt8, 7 as Int64))
        #expect(HeuristicInverter.areEquivalent(3.14 as Double, 3.14 as Double))
    }

    @Test("Non-equivalent values")
    func nonEquivalent() {
        #expect(HeuristicInverter.areEquivalent(42 as Int, 43.0 as Double) == false)
    }

    @Test("Fallback to string comparison for non-numeric types")
    func stringFallback() {
        #expect(HeuristicInverter.areEquivalent("hello", "hello"))
        #expect(HeuristicInverter.areEquivalent("hello", "world") == false)
    }

    // MARK: - Integration with Reflect

    @Test("Forward-only map Int→Double reflects successfully via heuristic inversion")
    func reflectIntToDoubleMap() throws {
        // Construct a forward-only .map(Int → Double) using Gen.liftF
        let gen: ReflectiveGenerator<Double> = Gen.liftF(.transform(
            kind: .map(
                forward: { Double($0 as! Int) as Any },
                inputType: "Int",
                outputType: "Double",
            ),
            inner: Gen.choose(in: 0 ... 100 as ClosedRange<Int>).erase(),
        ))
        let tree = try Interpreters.reflect(gen, with: 42.0 as Double)
        #expect(tree != nil)
    }

    @Test("Forward-only map Int→String still throws (unsupported type pair)")
    func reflectUnsupportedMapThrows() throws {
        let gen: ReflectiveGenerator<String> = Gen.liftF(.transform(
            kind: .map(
                forward: { String($0 as! Int) as Any },
                inputType: "Int",
                outputType: "String",
            ),
            inner: Gen.choose(in: 0 ... 100 as ClosedRange<Int>).erase(),
        ))
        #expect(throws: Interpreters.ReflectionError.self) {
            _ = try Interpreters.reflect(gen, with: "42")
        }
    }
}
