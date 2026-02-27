//
//  ReflectiveGenerator+NumericGenerators.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

import ExhaustCore

public extension ReflectiveGenerator {
    static func double(in range: ClosedRange<Double>? = nil) -> ReflectiveGenerator<Double> {
        Gen.choose(in: range)
    }

    static func double(in range: ClosedRange<Double>, scaling: SizeScaling<Double>) -> ReflectiveGenerator<Double> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func float(in range: ClosedRange<Float>? = nil) -> ReflectiveGenerator<Float> {
        Gen.choose(in: range)
    }

    static func float(in range: ClosedRange<Float>, scaling: SizeScaling<Float>) -> ReflectiveGenerator<Float> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func uint8(in range: ClosedRange<UInt8>? = nil) -> ReflectiveGenerator<UInt8> {
        Gen.choose(in: range)
    }

    static func uint8(in range: ClosedRange<UInt8>, scaling: SizeScaling<UInt8>) -> ReflectiveGenerator<UInt8> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func uint16(in range: ClosedRange<UInt16>? = nil) -> ReflectiveGenerator<UInt16> {
        Gen.choose(in: range)
    }

    static func uint16(in range: ClosedRange<UInt16>, scaling: SizeScaling<UInt16>) -> ReflectiveGenerator<UInt16> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func uint32(in range: ClosedRange<UInt32>? = nil) -> ReflectiveGenerator<UInt32> {
        Gen.choose(in: range)
    }

    static func uint32(in range: ClosedRange<UInt32>, scaling: SizeScaling<UInt32>) -> ReflectiveGenerator<UInt32> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func uint64(in range: ClosedRange<UInt64>? = nil) -> ReflectiveGenerator<UInt64> {
        Gen.choose(in: range)
    }

    static func uint64(in range: ClosedRange<UInt64>, scaling: SizeScaling<UInt64>) -> ReflectiveGenerator<UInt64> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func uint(in range: ClosedRange<UInt>? = nil) -> ReflectiveGenerator<UInt> {
        Gen.choose(in: range)
    }

    static func uint(in range: ClosedRange<UInt>, scaling: SizeScaling<UInt>) -> ReflectiveGenerator<UInt> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func int8(in range: ClosedRange<Int8>? = nil) -> ReflectiveGenerator<Int8> {
        Gen.choose(in: range)
    }

    static func int8(in range: ClosedRange<Int8>, scaling: SizeScaling<Int8>) -> ReflectiveGenerator<Int8> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func int16(in range: ClosedRange<Int16>? = nil) -> ReflectiveGenerator<Int16> {
        Gen.choose(in: range)
    }

    static func int16(in range: ClosedRange<Int16>, scaling: SizeScaling<Int16>) -> ReflectiveGenerator<Int16> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func int32(in range: ClosedRange<Int32>? = nil) -> ReflectiveGenerator<Int32> {
        Gen.choose(in: range)
    }

    static func int32(in range: ClosedRange<Int32>, scaling: SizeScaling<Int32>) -> ReflectiveGenerator<Int32> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func int64(in range: ClosedRange<Int64>? = nil) -> ReflectiveGenerator<Int64> {
        Gen.choose(in: range)
    }

    static func int64(in range: ClosedRange<Int64>, scaling: SizeScaling<Int64>) -> ReflectiveGenerator<Int64> {
        Gen.choose(in: range, scaling: scaling)
    }

    static func int(in range: ClosedRange<Int>? = nil) -> ReflectiveGenerator<Int> {
        Gen.choose(in: range)
    }

    static func int(in range: ClosedRange<Int>, scaling: SizeScaling<Int>) -> ReflectiveGenerator<Int> {
        Gen.choose(in: range, scaling: scaling)
    }
}
