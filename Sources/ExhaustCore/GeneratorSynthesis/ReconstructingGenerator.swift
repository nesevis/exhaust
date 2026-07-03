import Foundation

// MARK: - Generator Construction from Discovered Shapes

//
// Both reconstruction generators zip the shape's child generators and map the result through a closure. They differ only in that closure: ``makeReconstructingGenerator(_:shape:pin:codingPath:)`` runs `init(from:)` to build the value, while ``nestedReplayValueGenerator(for:)`` stops at the `ReplayValue` sub-tree the parent decodes inline. ``zipMap(_:_:)`` is the shared plumbing.

/// Zips `generators` and maps their generated values (as `[Any]`) through `transform`, producing a single type-erased generator.
private func zipMap(
    _ generators: ContiguousArray<AnyGenerator>,
    _ transform: @escaping ([Any]) throws -> Any
) -> AnyGenerator {
    let zipped: AnyGenerator = .impure(
        operation: .zip(generators),
        continuation: { .pure($0) }
    )
    return Gen.liftF(.transform(
        kind: .map(
            forward: { try transform($0 as! [Any]) },
            backward: nil,
            inputType: [Any].self,
            outputType: Any.self
        ),
        inner: zipped
    ))
}

/// Builds a generator that reconstructs a value of `type` from a discovered container shape, producing the built value type-erased to `Any`.
///
/// Zips the shape's child generators, reassembles their generated values into a ``ReplayValue``, and runs `type.init(from:)` against a ``ReplayDecoder``. When a generated value drives `init(from:)` to a branch the example did not cover, the reconstruction pins to `pin` and records a fallback rather than crashing; a genuine decode error still propagates. An ``ContainerShape/empty`` shape (nothing to synthesize) pins directly.
///
/// - Parameters:
///   - shape: The container shape discovered for this value.
///   - pin: The example value to fall back to when a generated sample reaches an uncovered branch.
///   - codingPath: The absolute path to this value. Seeds the replay decoder so a fallback reports the full path of the missed key rather than a path relative to this value.
func makeReconstructingGenerator<T: Decodable>(
    _: T.Type,
    shape: ContainerShape,
    pin: Any,
    codingPath: [any CodingKey]
) -> AnyGenerator {
    guard let (generators, rebuild) = shape.lowering() else {
        return Gen.just(pin).erase()
    }
    return zipMap(generators) { values in
        let replayValue = rebuild(values)
        do {
            return try T(from: ReplayDecoder(replayValue, codingPath: codingPath)) as Any
        } catch let miss as GenSchemaMiss {
            SynthesisDiagnostics.recordFallback(type: T.self, codingPath: miss.codingPath)
            return pin
        }
    }
}

/// Builds a generator that produces the nested ``ReplayValue`` for an inline nested container, from the shape its sub-decoder recorded.
///
/// Unlike ``makeReconstructingGenerator(_:shape:pin:codingPath:)``, this does not run `init(from:)` — the nested container is decoded inline by the parent type, so the parent's replay decoder reads this sub-tree directly through `nestedContainer(forKey:)`.
func nestedReplayValueGenerator(for shape: ContainerShape) -> AnyGenerator {
    guard let (generators, rebuild) = shape.lowering() else {
        return Gen.just(ReplayValue.keyed([:]) as Any).erase()
    }
    return zipMap(generators) { rebuild($0) as Any }
}

/// Builds an even-weighted pick over a `CaseIterable` enum's cases, or `nil` when the enum is uninhabited.
///
/// An enum with no cases has nothing to pick from; returning `nil` lets the caller fall through to the pin path rather than trapping in ``Gen/pick(choices:)``.
func makeCaseIterableGenerator(_ type: any (CaseIterable & Decodable).Type) -> AnyGenerator? {
    func build<Enum: CaseIterable & Decodable>(_: Enum.Type) -> AnyGenerator? {
        let cases = Array(Enum.allCases)
        guard cases.isEmpty == false else {
            return nil
        }
        return Gen.pick(
            choices: cases.map { (1, Gen.just($0 as Any)) }
        ).erase()
    }
    return build(type)
}

/// Wraps a field generator so the field varies between `nil` and a generated value, using the public ``ReflectiveGenerator/optional()`` so default weights stay consistent.
func wrapOptional(_ innerGenerator: AnyGenerator) -> AnyGenerator {
    ReflectiveGenerator(innerGenerator, isSynthesized: true).optional().gen.erase()
}
