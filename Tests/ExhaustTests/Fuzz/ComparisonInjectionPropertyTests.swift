//
//  ComparisonInjectionPropertyTests.swift
//  ExhaustTests
//
//  Property tests for the trace-cmp injection primitives. The example-based tests in ExhaustCoreTests pin specific cases; these state the laws over the whole domain, using the `#exhaust` macro that only the Exhaust module exposes.
//

import Exhaust
import ExhaustCore
import Testing

@Suite("Operand Reconstruction Properties")
struct OperandReconstructionPropertyTests {
    @Test("Int round-trips through its two's-complement operand word, at any sign")
    func intRoundTrips() {
        #exhaust(#gen(.int())) { value in
            Int.reconstruct(fromOperand: UInt64(bitPattern: Int64(value))) == value
        }
    }

    @Test("Double round-trips through its IEEE 754 operand word, including non-finite patterns")
    func doubleRoundTrips() {
        #exhaust(#gen(.double())) { value in
            Double.reconstruct(fromOperand: value.bitPattern)?.bitPattern == value.bitPattern
        }
    }
}

@Suite("Comparison Pool Properties")
struct ComparisonPoolPropertyTests {
    @Test("A site's ring holds exactly the last min(count, capacity) inserts, across capacities and schedules")
    func ringHoldsLastInserts() {
        #exhaust(#gen(.int(in: 1 ... 8), .int(in: 0 ... 1_000_000).array(length: 0 ... 30))) { capacity, rawValues in
            let values = rawValues.map { UInt64($0) }
            var pool = ComparisonPool(perSiteCapacity: capacity)
            for value in values {
                pool.insert(site: 0x1, value: value)
            }
            let kept = min(values.count, capacity)
            guard kept > 0 else {
                return pool.isEmpty
            }
            let expected = Array(values.suffix(kept)).sorted()
            let drawn = (0 ..< kept).compactMap {
                pool.drawValue(sitePick: 0.0, valuePick: (Double($0) + 0.5) / Double(kept))
            }.sorted()
            return drawn == expected
        }
    }
}
