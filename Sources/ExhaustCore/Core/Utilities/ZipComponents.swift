/// Checks a type-erased zip component list against its declared arity before positional reads.
///
/// The isomorph forward transforms read components positionally, so a list of the wrong length lands each value on a different generator's slot and force-casts across types. Rejecting the shape up front turns that trap into a reflection error the caller can report.
package func zipComponents(_ anyValues: Any, arity: Int) throws -> [Any] {
    guard let values = anyValues as? [Any], values.count == arity else {
        throw ReflectionError.zipWasWrongLengthOrType
    }
    return values
}

/// Converts a sequence result from `[Any]` to `[Element]` for ``Gen/arrayOf(_:_:)`` continuations.
///
/// Short arrays loop explicitly, which skips the stdlib array cast's setup and second allocation; long arrays use the stdlib cast, which is cheaper per element. The threshold of 16 is measured: 64 regressed nested integer arrays.
///
/// - Throws: ``GeneratorError/typeMismatch(expected:actual:)`` when the result is not a `[Any]`. A wrong element type traps.
@inline(__always)
package func sequenceElements<Element>(_ result: Any, as _: Element.Type) throws -> [Element] {
    guard let anyValues = result as? [Any] else {
        throw GeneratorError.typeMismatch(expected: "[Any]", actual: String(describing: type(of: result)))
    }
    if anyValues.count > 16 {
        guard let typed = anyValues as? [Element] else {
            throw GeneratorError.typeMismatch(expected: String(describing: [Element].self), actual: "[Any]")
        }
        return typed
    }
    var typed: [Element] = []
    typed.reserveCapacity(anyValues.count)
    for value in anyValues {
        // swiftlint:disable:next force_cast
        typed.append(value as! Element)
    }
    return typed
}
