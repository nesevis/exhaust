import Exhaust
import Testing

@Suite(
    "Property memory profile",
    .serialized,
    .exhaust(.budget(.extensive))
)
struct PropertyMemoryProfileTests {
    @Test("Extensive property run remains stable")
    func extensivePropertyRunRemainsStable() {
        let generator = #gen(
            .int(in: -10000 ... 10000)
                .array(length: 0 ... 64)
                .array(length: 0 ... 16),
            .string(length: 0 ... 256),
            .uint8().array(length: 0 ... 512)
        )

        var report: ExhaustReport?
        let counterexample = #exhaust(
            generator,
            .replay(7431),
            .suppress(.all),
            .onReport { report = $0 }
        ) { integerGroups, text, bytes in
            integerGroups.count <= 16
                && integerGroups.allSatisfy { $0.count <= 64 }
                && text.count <= 256
                && bytes.count <= 512
        }

        #expect(counterexample == nil)
        #expect(report?.randomSamplingInvocations == ExhaustBudget.extensive.samplingBudget)
        #expect((report?.screeningInvocations ?? 0) > 0)
    }
}
