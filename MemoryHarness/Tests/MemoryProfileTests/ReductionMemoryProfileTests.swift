import Exhaust
import Testing

@Suite(
    "Reduction memory profile",
    .serialized,
    .exhaust(.budget(.extensive))
)
struct ReductionMemoryProfileTests {
    @Test("Large collection failure reduces deterministically")
    func largeCollectionFailureReducesDeterministically() throws {
        let counterexample = try #require(
            #exhaust(
                #gen(.int(in: 0 ... 100).array(length: 0 ... 2048)),
                .replay(42),
                .suppress(.all)
            ) { values in
                values.count < 1024
            }
        )

        #expect(counterexample.count == 1024)
    }
}
