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
    ///   - type: The `Decodable` type to synthesize a generator for.
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
    ///   - type: The `Decodable` type to synthesize a generator for.
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

        // A top-level collection of a non-generable element type (for example `[Person]`) has no pre-configured generator, but its element can be discovered from a representative element of the example. This varies the collection's length and contents rather than pinning the whole value.
        if let discoveredCollection = makeDiscoveredCollectionGenerator(for: T.self, fromExample: jsonValue, codingPath: []) {
            let typed: Generator<T> = discoveredCollection.map { $0 as! T }
            return ReflectiveGenerator(typed, isSynthesized: true)
        }

        // The example-driven path: run `init(from:)` once to discover the type's shape, then reconstruct from it. `makeReconstructingGenerator` owns the zip-map-replay machinery and the catch-and-pin fallback; an empty shape (nothing to synthesize) pins to the example directly. The example value seeds the fallback at the root path `[]`.
        let discovery = DiscoveryDecoder(jsonValue: jsonValue)
        let exampleValue = try T(from: discovery)
        let reconstructing = makeReconstructingGenerator(
            T.self,
            shape: discovery.shape,
            pin: exampleValue,
            codingPath: []
        )
        let typed: Generator<T> = reconstructing.map { $0 as! T }
        return ReflectiveGenerator(typed, isSynthesized: true)
    }

    /// Returns the pre-configured generator for a top-level leaf or collection type, or `nil` when the type needs the discovery pass.
    ///
    /// Lifts the per-field dispatch the discovery pass already applies to nested values to the root: ``ExhaustGenerable`` types use their default generator, and standard-library collections of generable elements use their ``SynthesizableCollection`` generator.
    private static func rootGenerator<T>(for _: T.Type) -> Generator<T>? {
        resolveGenerator(for: T.self).map { anyGenerator in
            anyGenerator.map { $0 as! T }
        }
    }
}

/// Errors thrown during generator synthesis from a `Decodable` type.
package enum GeneratorSynthesizerError: Error {
    /// The input string could not be encoded as UTF-8 data.
    case invalidJSON
    /// The JSON structure did not match the expected container type (keyed, unkeyed, or single-value).
    case unexpectedContainer
}
