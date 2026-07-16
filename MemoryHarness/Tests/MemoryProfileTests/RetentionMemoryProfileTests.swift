import Exhaust
import Foundation
import Testing

@Suite(
    "Retained-memory profile",
    .serialized,
    .exhaust(.budget(.extensive))
)
struct RetentionMemoryProfileTests {
    @Test("Repeated property runs report retained footprint")
    func repeatedPropertyRunsReportRetainedFootprint() throws {
        let generator = #gen(
            .int(in: -10000 ... 10000).array(length: 0 ... 512),
            .asciiString(length: 0 ... 256)
        )
        let baseline = try #require(ProcessMemory.footprintBytes())
        printSample(label: "baseline", bytes: baseline)

        var postRunSamples: [UInt64] = []
        for iteration in 1 ... 5 {
            let counterexample = autoreleasepool {
                #exhaust(
                    generator,
                    .replay(5901),
                    .suppress(.all)
                ) { values, text in
                    values.count <= 512 && text.count <= 256
                }
            }

            #expect(counterexample == nil)
            let footprint = try #require(ProcessMemory.footprintBytes())
            postRunSamples.append(footprint)
            printSample(label: "iteration \(iteration)", bytes: footprint)
        }

        let first = try #require(postRunSamples.first)
        let last = try #require(postRunSamples.last)
        let growth = Int64(last) - Int64(first)
        print(
            "memory-retention: first-to-last growth "
                + "\(String(format: "%.1f", Double(growth) / 1_048_576)) MiB"
        )
    }

    private func printSample(label: String, bytes: UInt64) {
        let mebibytes = Double(bytes) / 1_048_576
        print("memory-retention: \(label) \(String(format: "%.1f", mebibytes)) MiB")
    }
}
