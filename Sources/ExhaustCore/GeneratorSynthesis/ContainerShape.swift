import Foundation

/// The container shape a ``DiscoveryDecoder`` observed for one decoder level, with a child generator per decoded field.
///
/// A keyed level carries the `CodingKey` string for each field so the example decoder can address values by name rather than by position. The shape lowers to the child generators to zip and a closure that reassembles their generated values into a ``ExampleValue``.
package enum ContainerShape {
    /// A keyed container: one child per `decode`/`decodeIfPresent`/`nestedContainer(forKey:)` call.
    case keyed([KeyedChild])
    /// A heterogeneous unkeyed container: one element per decoded value or nested decoder, in order, with the length fixed to the example (a positional/tuple decode that wants exactly this sequence).
    case unkeyed([UnkeyedElement])
    /// A homogeneous unkeyed container: every element decoded to the same type, so the length varies like an array rather than being fixed to the example.
    case homogeneousArray(element: AnyGenerator)
    /// A single-value container: one generator.
    case single(AnyGenerator)
    /// Nothing was recorded — the discovery pass could not synthesize anything for this level.
    case empty

    /// Whether the discovery pass recorded no generators for this level.
    var isEmpty: Bool {
        if case .empty = self {
            return true
        }
        return false
    }

    /// Lowers the shape into the child generators to zip and a closure that reassembles their generated values into a ``ExampleValue``. Returns `nil` for ``empty``.
    func lowering() -> (generators: ContiguousArray<AnyGenerator>, rebuild: ([Any]) -> ExampleValue)? {
        switch self {
            case let .keyed(children):
                let generators = ContiguousArray(children.map(\.generator))
                let keyStrings = children.map(\.key)
                let replayFlags = children.map(\.producesExampleValue)
                let optionalFlags = children.map(\.isOptional)
                return (generators, { values in
                    .positionalKeyed(
                        keys: keyStrings,
                        values: values,
                        producesExampleValue: replayFlags,
                        isOptional: optionalFlags
                    )
                })
            case let .unkeyed(elements):
                return (ContiguousArray(elements.map(\.generator)), { values in
                    .unkeyed(zip(elements, values).map { element, value in
                        element.producesExampleValue ? (value as! ExampleValue) : .leaf(value)
                    })
                })
            case let .homogeneousArray(element):
                let arrayGenerator: AnyGenerator = Gen.arrayOf(element).erase()
                return (ContiguousArray([arrayGenerator]), { values in
                    .rawUnkeyed(values[0] as! [Any])
                })
            case let .single(generator):
                return (ContiguousArray([generator]), { values in
                    .leaf(values[0])
                })
            case .empty:
                return nil
        }
    }
}

/// One field of a keyed container shape.
package struct KeyedChild {
    /// The `CodingKey` string the example decoder addresses this field by.
    let key: String
    /// Generates either the field's built value (when ``producesExampleValue`` is `false`) or a nested ``ExampleValue`` sub-tree (when `true`).
    let generator: AnyGenerator
    /// Whether ``generator`` produces a ``ExampleValue`` directly (a nested container) rather than a value to wrap as a leaf.
    let producesExampleValue: Bool
    /// Whether this field was decoded via `decodeIfPresent` and may produce `nil`.
    let isOptional: Bool
}

/// One positional element of a heterogeneous unkeyed container shape.
package struct UnkeyedElement {
    /// Generates either a decoded value (when ``producesExampleValue`` is `false`) or a nested ``ExampleValue`` sub-tree from a `superDecoder()` call (when `true`).
    let generator: AnyGenerator
    /// Whether ``generator`` produces a ``ExampleValue`` directly rather than a value to wrap as a leaf.
    let producesExampleValue: Bool
}
