import Exhaust
import ExhaustCore
import ExhaustTestSupport
import Testing

@Suite("Derived depth controls")
struct DerivedDepthControlTests {
    @Test("Derived generation and reflection record tagged depth controls")
    func taggedDepth() throws {
        let generator = DepthControlTree.gen(.budget(.custom(recursion: 20, nodes: 3)))
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
        let (value, generated) = try #require(try interpreter.next())
        let reflected = try #require(try Interpreters.reflect(generator.gen, with: value))
        let drawnControls = depthControls(in: generated)
        let reflectedControls = depthControls(in: reflected)
        #expect(drawnControls.count == 1)
        #expect(reflectedControls.count == 1)
        let (drawnDepth, drawnMetadata) = try #require(drawnControls.first)
        let (reflectedDepth, reflectedMetadata) = try #require(reflectedControls.first)
        #expect(drawnDepth.tag == .depthControl)
        #expect(reflectedDepth.tag == .depthControl)
        #expect(drawnDepth.bitPattern64 == 14)
        #expect(reflectedDepth.bitPattern64 == 20)
        #expect(drawnMetadata.validRange == 0 ... 20)
        #expect(reflectedMetadata.validRange == 0 ... 20)
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
        let layers = (0 ... 20).map {
            DepthControlTree.gen(
                recursion: $0,
                .budget(.custom(recursion: $0, nodes: 3))
            )
        }
        for scaling in scalings {
            let generator = DepthControlTree.gen(
                .budget(.custom(recursion: 20, nodes: 3)),
                scaling: scaling
            )
            let reference = ReflectiveGenerator<Int>.int(in: 0 ... 20, scaling: scaling).gen._bound(
                forward: { recursion in layers[recursion].gen.erase() },
                backward: { (_: DepthControlTree) in 20 }
            )
            try expectMatchingRandomStream(generator.gen, reference: reference, seed: 42, size: size, draws: 30)
        }
    }

    @Test("Acyclic derivation omits recursive fuel choices")
    func acyclicFuel() throws {
        let generator = DepthControlEnvelope.gen(.budget(.custom(recursion: 20, nodes: 3)))
        var interpreter = ValueAndChoiceTreeInterpreter(generator.gen, seed: 42, sizeOverride: 100)
        let (_, generated) = try #require(try interpreter.next())
        #expect(depthControls(in: generated).isEmpty)
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
        expectSuccessfulExamination(report, samples: 50)
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

private func depthControls(in tree: ChoiceTree) -> [(ChoiceValue, ChoiceMetadata)] {
    switch tree {
        case let .choice(value, metadata):
            value.tag == .depthControl ? [(value, metadata)] : []
        case let .bind(_, inner, bound):
            depthControls(in: inner) + depthControls(in: bound)
        case let .group(children, _, _), let .resize(_, children):
            children.flatMap { depthControls(in: $0) }
        case let .sequence(elements, _):
            elements.flatMap { depthControls(in: $0) }
        case let .branch(branch):
            depthControls(in: branch.choice)
        case .just, .getSize:
            []
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

@Exhaustable
private indirect enum DepthControlTree: Equatable {
    case leaf
    case node(DepthControlTree)
}
