/// Checks a type-erased zip component list against its declared arity before positional reads.
///
/// The isomorph forward transforms read components positionally, so a list of the wrong length lands each value on a different generator's slot and force-casts across types. Rejecting the shape up front turns that trap into a reflection error the caller can report.
package func zipComponents(_ anyValues: Any, arity: Int) throws -> [Any] {
    guard let values = anyValues as? [Any], values.count == arity else {
        throw ReflectionError.zipWasWrongLengthOrType
    }
    return values
}
