import Foundation

/// The container shape a ``DiscoveryDecoder`` observed for one decoder level, with a child generator per decoded field.
///
/// A keyed level carries the `CodingKey` string for each field so the replay decoder can address values by name rather than by position. The shape lowers to the child generators to zip and a closure that reassembles their generated values into a ``ReplayValue``.
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

    /// Lowers the shape into the child generators to zip and a closure that reassembles their generated values into a ``ReplayValue``. Returns `nil` for ``empty``.
    func lowering() -> (generators: ContiguousArray<AnyGenerator>, rebuild: ([Any]) -> ReplayValue)? {
        switch self {
            case let .keyed(children):
                let generators = ContiguousArray(children.map(\.generator))
                return (generators, { values in
                    var fields = [String: ReplayValue](minimumCapacity: children.count)
                    for (index, child) in children.enumerated() {
                        // A nested-container child's generator already produces a `ReplayValue` sub-tree; a value child's generator produces the built value, wrapped here as a leaf. A custom init may decode the same key twice; last write wins, which also avoids a duplicate-key trap.
                        fields[child.key] = child.producesReplayValue ? (values[index] as! ReplayValue) : .leaf(values[index])
                    }
                    return .keyed(fields)
                })
            case let .unkeyed(elements):
                return (ContiguousArray(elements.map(\.generator)), { values in
                    .unkeyed(zip(elements, values).map { element, value in
                        element.producesReplayValue ? (value as! ReplayValue) : .leaf(value)
                    })
                })
            case let .homogeneousArray(element):
                // Reuse the array combinator's length distribution: one generator produces the whole varying-length array, which the rebuild unpacks into unkeyed leaves.
                let arrayGenerator: AnyGenerator = Gen.arrayOf(element).erase()
                return (ContiguousArray([arrayGenerator]), { values in
                    .unkeyed((values[0] as! [Any]).map(ReplayValue.leaf))
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
    /// The `CodingKey` string the replay decoder addresses this field by.
    let key: String
    /// Generates either the field's built value (when ``producesReplayValue`` is `false`) or a nested ``ReplayValue`` sub-tree (when `true`).
    let generator: AnyGenerator
    /// Whether ``generator`` produces a ``ReplayValue`` directly (a nested container) rather than a value to wrap as a leaf.
    let producesReplayValue: Bool
}

/// One positional element of a heterogeneous unkeyed container shape.
package struct UnkeyedElement {
    /// Generates either a decoded value (when ``producesReplayValue`` is `false`) or a nested ``ReplayValue`` sub-tree from a `superDecoder()` call (when `true`).
    let generator: AnyGenerator
    /// Whether ``generator`` produces a ``ReplayValue`` directly rather than a value to wrap as a leaf.
    let producesReplayValue: Bool
}
