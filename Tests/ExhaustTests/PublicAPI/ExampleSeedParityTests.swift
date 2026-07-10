import Exhaust
import Testing

// MARK: - #example / #exhaust seed parity

//
// #example runs the same interpreter as the #exhaust sampling phase, so the same seed must recreate
// the same values: the count overload one for one from the first iteration, and an encoded seed with
// an iteration suffix ("XXXX-3") the exact value that iteration generated, size ramp included.

@Suite("#example seed parity")
struct ExampleSeedParityTests {
    private static let parityGen = #gen(.int(in: 0 ... 100).array(length: 0 ... 20))
    private static let parseSeed: UInt64 = 1337
    private static let sampleCount = 20

    @Test("#example(count:seed:) recreates the values #exhaust sampled with the same seed")
    func arrayParity() throws {
        let sampled = Self.recordSampledValues()
        #expect(sampled.count == Self.sampleCount)

        let recreated = try #example(
            Self.parityGen,
            count: Self.sampleCount,
            seed: .numeric(Self.parseSeed)
        )
        #expect(recreated == sampled)
    }

    @Test("#example(seed:) with an encoded iteration seed recreates that iteration's value")
    func iterationParity() throws {
        let sampled = Self.recordSampledValues()

        for iteration in [1, 7, Self.sampleCount] {
            let encoded = ReplaySeed.Resolved.sampling(seed: Self.parseSeed, iteration: iteration).encoded
            let recreated = try #example(Self.parityGen, seed: .encoded(encoded))
            #expect(recreated == sampled[iteration - 1], "iteration \(iteration), seed \(encoded)")
        }
    }

    @Test("#example(count:seed:) with an encoded iteration seed starts at that iteration")
    func iterationOffsetArrayParity() throws {
        let sampled = Self.recordSampledValues()

        let encoded = ReplaySeed.Resolved.sampling(seed: Self.parseSeed, iteration: 5).encoded
        let recreated = try #example(Self.parityGen, count: 10, seed: .encoded(encoded))
        #expect(recreated == Array(sampled[4 ..< 14]))
    }

    /// Runs the `#exhaust` sampling phase with a fixed seed and no screening, recording every value the property saw.
    private static func recordSampledValues() -> [[Int]] {
        let recorder = ValueRecorder<[Int]>()
        #exhaust(
            parityGen,
            .replay(.numeric(parseSeed)),
            .budget(.custom(screening: 0, sampling: sampleCount)),
            .suppress(.all)
        ) { value in
            recorder.append(value)
            return true
        }
        return recorder.values
    }
}

// MARK: - Helpers

/// Collects values from a `@Sendable` property closure. Safe without a lock because `#exhaust` runs single-threaded here (no `.parallelize`).
private final class ValueRecorder<Value>: @unchecked Sendable {
    private var storage: [Value] = []

    func append(_ value: Value) {
        storage.append(value)
    }

    var values: [Value] {
        storage
    }
}
