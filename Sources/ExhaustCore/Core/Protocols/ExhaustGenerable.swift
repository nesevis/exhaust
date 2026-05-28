/// Provides a default generator for types that ``GeneratorSynthesizer`` can generate as leaf values.
///
/// During the discovery pass, the ``GeneratorSynthesizer`` checks `as? ExhaustGenerable.Type` to distinguish leaf types (which have built-in generators) from nested `Decodable` types (which require recursive descent). When a type conforms, its ``defaultGenerator`` is recorded directly. When it does not, the decoder recurses into `T.init(from:)` to build a sub-generator.
///
/// The return type is ``AnyGenerator`` rather than ``ReflectiveGenerator`` because the protocol must be non-generic to support the runtime `as?` check. Each conformance must return a generator whose output values match `Self` at runtime — the type erasure is structural, not semantic.
package protocol ExhaustGenerable {
    /// A default generator for this type, type-erased to ``AnyGenerator``.
    static var defaultGenerator: AnyGenerator { get }
}
