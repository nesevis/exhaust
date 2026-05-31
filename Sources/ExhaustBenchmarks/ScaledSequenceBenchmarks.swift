import Benchmark
import Exhaust

func registerScaledSequenceBenchmarks() {
    let length = 10000

    // Scaled elements (D2 fast path): .int() uses exponential scaling → applyScaling + pow() per element.
    let scaledIntArray = #gen(.int()).array(length: length)
    benchmark("Scaled Int array, \(length)") {
        _ = #exhaust(scaledIntArray, .suppress(.issueReporting), .replay(1337)) { _ in true }
    }

    let scaledDoubleArray = #gen(.double()).array(length: length)
    benchmark("Scaled Double array, \(length)") {
        _ = #exhaust(scaledDoubleArray, .suppress(.issueReporting), .replay(1337)) { _ in true }
    }

    let scaledInt16Array = #gen(.int16()).array(length: length)
    benchmark("Scaled Int16 array, \(length)") {
        _ = #exhaust(scaledInt16Array, .suppress(.issueReporting), .replay(1337)) { _ in true }
    }

    // Unscaled elements (D2 fallback path): explicit subrange, no scaling.
    let unscaledIntArray = #gen(.int(in: 0 ... 1000)).array(length: length)
    benchmark("Unscaled Int array, \(length)") {
        _ = #exhaust(unscaledIntArray, .suppress(.issueReporting), .replay(1337)) { _ in true }
    }

    // Mixed: scaled element inside a struct-like zip (top-level is zip, not chooseBits → fallback).
    let pairArray = #gen(.int(), .double()).array(length: length)
    benchmark("Scaled pair array, \(length)") {
        _ = #exhaust(pairArray, .suppress(.issueReporting), .replay(1337)) { _ in true }
    }
}
