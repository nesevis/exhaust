import Exhaust
import ExhaustCore
import Testing

@Suite("Derived depth controls")
struct DerivedDepthControlTests {
    @Test("Derived generation and reflection record tagged depth controls")
    func taggedDepth() throws {
        let generator = DepthControlEnvelope.gen(maximumDepth: 20)
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 1)
        let (value, generated) = try #require(try interpreter.next())
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: value))
        guard case let .bind(_, .choice(drawnDepth, drawnMetadata), _) = generated,
              case let .bind(_, .choice(reflectedDepth, reflectedMetadata), _) = reflected
        else {
            Issue.record("Expected root depth-control binds")
            return
        }
        #expect(drawnDepth.tag == .depthControl)
        #expect(reflectedDepth.tag == .depthControl)
        #expect(drawnDepth.bitPattern64 == 1)
        #expect(reflectedDepth.bitPattern64 == 20)
        #expect(drawnMetadata.validRange == 1 ... 20)
        #expect(reflectedMetadata.validRange == 1 ... 20)
        #expect(ChoiceTree.compareValues(generated, reflected) == nil)
        #expect(try Interpreters.replay(generator.gen, using: reflected) == value)
    }

    @Test("Tagged depth selection preserves the previous signed scaling and random stream", arguments: [UInt64(1), 25, 50, 100])
    func scalingParity(size: UInt64) throws {
        let scalings: [SizeScaling<Int>] = [
            .constant, .linear, .exponential,
            .linearFrom(origin: Int.min), .linearFrom(origin: 7), .linearFrom(origin: Int.max),
            .exponentialFrom(origin: Int.min), .exponentialFrom(origin: 7), .exponentialFrom(origin: Int.max),
        ]
        let layers = (1 ... 20).map { DepthControlEnvelope.gen(depth: $0) }
        for scaling in scalings {
            let generator = DepthControlEnvelope.gen(maximumDepth: 20, scaling: scaling)
            // Reproduces the old root depth draw independently of the new depth-control chooser.
            let reference = ReflectiveGenerator<Int>.int(in: 1 ... 20, scaling: scaling).gen._bound(
                forward: { depth in layers[depth - 1].gen.erase() },
                backward: { (_: DepthControlEnvelope) in 20 }
            )
            var actualInterpreter = ValueAndChoiceTreeInterpreter(
                Gen.zip(generator.gen, Gen.choose(in: UInt64.min ... UInt64.max)),
                seed: 42,
                sizeOverride: size
            )
            var referenceInterpreter = ValueAndChoiceTreeInterpreter(
                Gen.zip(reference, Gen.choose(in: UInt64.min ... UInt64.max)),
                seed: 42,
                sizeOverride: size
            )
            for _ in 0 ..< 30 {
                let actual = try #require(try actualInterpreter.next())
                let expected = try #require(try referenceInterpreter.next())
                #expect(actual.0.0 == expected.0.0)
                #expect(actual.0.1 == expected.0.1)
            }
        }
    }

    @Test("Examine accepts different depth allowances in Gen.recursive")
    func examinesRecursiveGenerator() {
        let base = ReflectiveGenerator<DepthControlTree>.oneOf([.just(.leaf)])
        let recursive = Gen.recursive(base: base.gen, depthRange: 0 ... 3) { recurse, _ in
            let child = recurse().wrapped(isReflective: true)
            return ReflectiveGenerator<DepthControlTree>.oneOf(
                .just(.leaf),
                #gen(child) { DepthControlTree.node($0) }
            ).gen
        }.wrapped(isReflective: true)
        let report = #examine(recursive, .samples(50), .replay(42), .suppress(.logs)) { first, second in
            first == second
        }
        #expect(report.passed)
        #expect(report.valuesGenerated == 50)
        #expect(report.reflectionRoundTripSuccesses == 50)
        #expect(report.replayDeterminismSuccesses == 50)
    }

    @Test("Examine still rejects incorrect payload reflection beneath a depth control")
    func rejectsIncorrectPayload() {
        let payload = ReflectiveGenerator<Int>.int(in: 1 ... 10).mapped(
            forward: { $0 * 2 },
            backward: { $0 / 2 + 1 }
        )
        let generator: ReflectiveGenerator<Int> = Gen.chooseDepth(in: 0 ... 3)._bound(
            forward: { _ in payload.gen },
            backward: { _ in UInt64(3) }
        ).wrapped(isReflective: true)
        let report = #examine(generator, .samples(10), .replay(42), .suppress(.all))
        #expect(report.passed == false)
        #expect(report.valuesGenerated == 10)
        #expect(report.reflectionRoundTripSuccesses == 0)
        #expect(report.failures.count == 10)
        #expect(report.failures.allSatisfy { failure in
            switch failure {
                case .reflectionRoundTripMismatch, .reflectionFailed:
                    true
                default:
                    false
            }
        })
    }
}

// MARK: - Fixtures

@Exhaustable
private struct DepthControlLeaf: Equatable {
    let number: Int
}

@Exhaustable
private struct DepthControlEnvelope: Equatable {
    let payload: DepthControlLeaf
}

private indirect enum DepthControlTree: Equatable {
    case leaf
    case node(DepthControlTree)
}
