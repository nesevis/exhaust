import Benchmark
import Exhaust

/// Forces evaluation of its argument so the optimizer cannot eliminate an otherwise-unused allocation.
@inline(never)
private func opaqueSink(_: some Any) {}

func registerSequenceLengthBenchmarks() {
//    benchmark("Baseline: reserve + UInt64.random loop, count 65535") {
//        var array = [UInt64]()
//        array.reserveCapacity(Int(UInt16.max))
//        for _ in 0 ..< Int(UInt16.max) {
//            array.append(UInt64.random(in: UInt64.min ... UInt64.max))
//        }
//        opaqueSink(array)
//    }
//
//    benchmark("Baseline: reserve + Xoshiro256 loop, count 65535") {
//        var array = [UInt64]()
//        array.reserveCapacity(Int(UInt16.max))
//        var rng = Xoshiro256()
//        for _ in 0 ..< Int(UInt16.max) {
//            array.append(rng.next())
//        }
//        opaqueSink(array)
//    }

    // Each iteration generates one fixed-length collection on the value-only path:
    // `.replay(1337)` forces a single sample (no coverage phase; the property passes so no reduction).
    let lengths = [Int(UInt16.max)]

    for length in lengths {
        let intArray = #gen(.int(in: 0 ... 1000)).array(length: length)
        benchmark("Gen: Int array, length \(length)") {
            _ = #exhaust(intArray, .suppress(.issueReporting), .replay(1337)) { _ in true }
        }

        let unicodeString = #gen(.string(length: UInt64(length) ... UInt64(length)))
        benchmark("Gen: Unicode string, length \(length)") {
            _ = #exhaust(unicodeString, .suppress(.issueReporting), .replay(1337)) { _ in true }
        }

        let asciiStringGen = #gen(.asciiString(length: UInt64(length) ... UInt64(length)))
        benchmark("Gen: ASCII string, length \(length)") {
            _ = #exhaust(asciiStringGen, .suppress(.issueReporting), .replay(1337)) { _ in true }
        }
    }
}
