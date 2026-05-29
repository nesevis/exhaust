import Foundation

/// Builds a ``ReflectiveGenerator`` from a `Decodable` type and an example JSON value.
///
/// Runs `T.init(from:)` once against the provided JSON to discover the type's decode call pattern, recording a generator for each field. The result is a normal ``ReflectiveGenerator`` — all interpreters, the reducer, and coverage analysis treat it identically to a hand-written generator.
///
/// The generator is forward-only (no reflection support). Types that cannot be mapped to a built-in generator fall back to `.just(decodedValue)` using the concrete value from the JSON example.
package enum GeneratorSynthesizer {
    /// Builds a generator from an example JSON `Data` value.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to synthesise a generator for.
    ///   - data: Example JSON data whose structure matches `T`.
    /// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
    package static func makeGenerator<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> ReflectiveGenerator<T> {
        let jsonValue = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try makeGenerator(type, jsonValue: jsonValue)
    }

    /// Builds a generator from an example JSON string.
    ///
    /// - Parameters:
    ///   - type: The `Decodable` type to synthesise a generator for.
    ///   - string: Example JSON string whose structure matches `T`.
    /// - Returns: A ``ReflectiveGenerator`` that produces arbitrary values of type `T`.
    package static func makeGenerator<T: Decodable>(
        _ type: T.Type,
        from string: String
    ) throws -> ReflectiveGenerator<T> {
        guard let data = string.data(using: .utf8) else {
            throw GeneratorSynthesizerError.invalidJSON
        }
        return try makeGenerator(type, from: data)
    }

    private static func makeGenerator<T: Decodable>(
        _: T.Type,
        jsonValue: Any
    ) throws -> ReflectiveGenerator<T> {
        // A top-level leaf or collection type resolves to its pre-configured generator directly, without running `init(from:)`. This covers single-value types (Date, UUID, URL, Data, Decimal, CGFloat, and the primitives) and top-level collections of generable elements — both of which the example-driven discovery pass cannot characterize on its own (a top-level array records no child generators, and a single-value type would record the inner primitive rather than itself).
        if let rootGenerator = rootGenerator(for: T.self) {
            return ReflectiveGenerator(rootGenerator, isSynthesized: true)
        }

        let discovery = DiscoveryDecoder(jsonValue: jsonValue)
        let exampleValue = try T(from: discovery)
        let childGenerators = ContiguousArray(discovery.childGenerators)

        // No child generators means the discovery pass found nothing to synthesize — a collection of non-generable elements, or a type whose decode produced no leaves. Pin to the example at build time instead of building an empty zip that the replay pass would immediately over-read. This pinning is structural and surfaces through `#examine`'s pinned-field report, so it does not emit a per-sample fallback warning.
        guard childGenerators.isEmpty == false else {
            return ReflectiveGenerator(Gen.just(exampleValue), isSynthesized: true)
        }

        let zipped: AnyGenerator = .impure(
            operation: .zip(childGenerators),
            continuation: { .pure($0) }
        )

        let generator = Gen.liftF(.transform(
            kind: .map(
                forward: { values in
                    // A generated value can drive a hand-written `init(from:)` down a branch the example never exercised, exhausting the tape. Catch that and pin this sample to the example rather than letting it crash; a genuine decode error still propagates.
                    do {
                        let replay = ReplayDecoder(values: values as! [Any])
                        return try T(from: replay)
                    } catch let miss as GenSchemaMiss {
                        SynthesisDiagnostics.recordFallback(type: T.self, codingPath: miss.codingPath)
                        return exampleValue
                    }
                },
                inputType: [Any].self,
                outputType: T.self
            ),
            inner: zipped
        )) as Generator<T>

        return ReflectiveGenerator(generator, isSynthesized: true)
    }

    /// Returns the pre-configured generator for a top-level leaf or collection type, or `nil` when the type needs the discovery pass.
    ///
    /// Mirrors the per-field dispatch the discovery pass already applies to nested values, lifted to the root: ``ExhaustGenerable`` types use their default generator, and standard-library collections of generable elements use their ``SynthesizableCollection`` generator.
    private static func rootGenerator<T>(for _: T.Type) -> Generator<T>? {
        if let generable = T.self as? ExhaustGenerable.Type {
            return generable.defaultGenerator.map { $0 as! T }
        }
        if let collection = T.self as? SynthesizableCollection.Type,
           let collectionGenerator = collection.synthesizedGenerator
        {
            return collectionGenerator.map { $0 as! T }
        }
        return nil
    }
}

/// Errors thrown during generator synthesis from a `Decodable` type.
package enum GeneratorSynthesizerError: Error {
    /// The input string could not be encoded as UTF-8 data.
    case invalidJSON
    /// The JSON structure did not match the expected container type (keyed, unkeyed, or single-value).
    case unexpectedContainer
}
