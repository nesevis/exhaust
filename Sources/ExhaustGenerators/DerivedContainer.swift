import ExhaustCore

/// Describes a standard container without resolving or constructing its contents.
///
/// The derivation plan resolves every child through its own override and default rules. At a depth where any child is unavailable, the empty generator supplies a terminating value without requesting a generator at a negative depth.
package protocol DerivedContainer {
    static var derivationRecipe: DerivedContainerRecipe { get }
}

/// Separates empty, unrestricted, and budgeted construction. Child order matches the factory's positional inputs, including key before value for dictionaries. Budgeted rows share completed child generators across every entry, not their node allowance.
package struct DerivedContainerRecipe {
    let type: Any.Type
    let childTypes: [Any.Type]

    /// The container's own structural ceiling, independent of any node allowance. `Optional` holds at most one element; the rest are unbounded.
    let maximumCount: Int?

    /// Matches the public container factory; deduplicating containers do not promise reflection even when their elements do.
    let isReflective: Bool

    /// Produces only the container's empty value, and rejects a nonempty reflection target rather than replaying it as empty.
    let empty: AnyGenerator

    /// Builds the factory's own size-scaled cardinality, used when no node allowance and no bounded state space applies.
    let build: ([AnyGenerator]) -> AnyGenerator

    /// Builds a cardinality capped at the given count, used when a bounded state space narrows the default without a node allowance.
    let buildWithin: (Int, [AnyGenerator]) -> AnyGenerator

    /// Builds one fixed-cardinality layer, so a node allowance can divide the same remainder among a known number of elements.
    let buildExactly: (Int, [AnyGenerator]) -> AnyGenerator

    /// Samples through the given cardinality while retaining every prebuilt layer for reflection. The value's own count recovers the layer without generation state.
    let selectCount: (Int, [AnyGenerator]) -> AnyGenerator
}

extension Array: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        DerivedContainerRecipe(
            type: Self.self,
            childTypes: [Element.self],
            maximumCount: nil,
            isReflective: true,
            empty: emptyContainer(Self()) { $0.isEmpty },
            build: { children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.arrayOf(element).erase()
            },
            buildWithin: { maximumCount, children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.arrayOf(
                    element,
                    within: UInt64(0) ... UInt64(maximumCount),
                    scaling: .linear,
                    isLengthRangeExplicit: false
                ).erase()
            },
            buildExactly: { count, children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.arrayOf(element, exactly: UInt64(count)).erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(
                    layers,
                    maximumGeneratedCount: maximumGeneratedCount,
                    count: { (value: Self) in value.count }
                )
            }
        )
    }
}

extension Optional: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        DerivedContainerRecipe(
            type: Self.self,
            childTypes: [Wrapped.self],
            maximumCount: 1,
            isReflective: true,
            empty: emptyContainer(none) { value in
                guard case .none = value else {
                    return false
                }
                return true
            },
            build: { children in
                let wrapped: Generator<Wrapped> = children[0].map { $0 as! Wrapped }
                return ReflectiveGenerator<Wrapped>
                    .optional(wrapped.wrapped(isReflective: true))
                    .gen
                    .erase()
            },
            buildWithin: { _, children in
                let wrapped: Generator<Wrapped> = children[0].map { $0 as! Wrapped }
                return ReflectiveGenerator<Wrapped>
                    .optional(wrapped.wrapped(isReflective: true))
                    .gen
                    .erase()
            },
            buildExactly: { _, children in
                let wrapped: Generator<Wrapped> = children[0].map { $0 as! Wrapped }
                return wrapped.liftToOptional().erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(
                    layers,
                    maximumGeneratedCount: maximumGeneratedCount,
                    count: { (value: Self) in value == nil ? 0 : 1 }
                )
            }
        )
    }
}

extension Set: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        DerivedContainerRecipe(
            type: Self.self,
            childTypes: [Element.self],
            maximumCount: nil,
            isReflective: false,
            empty: emptyContainer(Self()) { $0.isEmpty },
            build: { children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.setOf(element).erase()
            },
            buildWithin: { maximumCount, children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.setOf(
                    element,
                    within: UInt64(0) ... UInt64(maximumCount),
                    scaling: .linear,
                    isLengthRangeExplicit: false
                ).erase()
            },
            buildExactly: { count, children in
                let element: Generator<Element> = children[0].map { $0 as! Element }
                return Gen.setOf(element, exactly: UInt64(count)).erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(
                    layers,
                    maximumGeneratedCount: maximumGeneratedCount,
                    count: { (value: Self) in value.count }
                )
            }
        )
    }
}

extension Dictionary: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        DerivedContainerRecipe(
            type: Self.self,
            childTypes: [Key.self, Value.self],
            maximumCount: nil,
            isReflective: false,
            empty: emptyContainer(Self()) { $0.isEmpty },
            build: { children in
                let key: Generator<Key> = children[0].map { $0 as! Key }
                let value: Generator<Value> = children[1].map { $0 as! Value }
                return Gen.dictionaryOf(key, value).erase()
            },
            buildWithin: { maximumCount, children in
                let key: Generator<Key> = children[0].map { $0 as! Key }
                let value: Generator<Value> = children[1].map { $0 as! Value }
                return Gen.dictionaryOf(
                    key,
                    value,
                    within: UInt64(0) ... UInt64(maximumCount),
                    scaling: .linear,
                    isLengthRangeExplicit: false
                ).erase()
            },
            buildExactly: { count, children in
                let key: Generator<Key> = children[0].map { $0 as! Key }
                let value: Generator<Value> = children[1].map { $0 as! Value }
                return Gen.dictionaryOf(key, value, exactly: UInt64(count)).erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(
                    layers,
                    maximumGeneratedCount: maximumGeneratedCount,
                    count: { (value: Self) in value.count }
                )
            }
        )
    }
}

// MARK: - Helpers

extension ReflectiveGenerator {
    /// Erases the payload type without discarding the capability used by enclosing derived products and containers. This adds no generator operations or random draws.
    func erasedForDerivation() -> ReflectiveGenerator<Any> {
        gen.erase().wrapped(isReflective: isReflective)
    }
}

/// Selects a completed cardinality layer; reflection recovers cardinality from the value, never from hidden generation state. The layer array contains an empty layer followed by positive-count layers.
private func boundedContainer<Value>(
    _ layers: [AnyGenerator],
    maximumGeneratedCount: Int,
    count: @escaping (Value) -> Int
) -> AnyGenerator {
    let maximumReflectableCount = layers.count - 1
    let reflectableRange = UInt64(0) ... UInt64(maximumReflectableCount)
    switch maximumGeneratedCount < maximumReflectableCount {
        case true:
            let countGenerator = Gen.chooseDerived(
                in: reflectableRange,
                samplingWithin: UInt64(0) ... UInt64(maximumGeneratedCount)
            )
            let generator: Generator<Value> = countGenerator._bound(
                forward: { selectedCount in layers[Int(selectedCount)] },
                backward: { (value: Value) in UInt64(count(value)) }
            )
            return Gen.comap(
                { (value: Value) in
                    let selectedCount = count(value)
                    guard selectedCount <= maximumReflectableCount else {
                        throw ReflectionError.inputWasOutOfGeneratorRange(
                            String(selectedCount),
                            range: "0...\(maximumReflectableCount)"
                        )
                    }
                    return value
                },
                generator
            ).erase()
        case false:
            let generator: Generator<Value> = Gen.choose(
                in: reflectableRange,
                scaling: .linear
            )._bound(
                forward: { selectedCount in layers[Int(selectedCount)] },
                backward: { (value: Value) in UInt64(count(value)) }
            )
            return generator.erase()
    }
}

/// Rejects nonempty reflection targets even when the element type is not Equatable. A bare `just` accepts any target and would replay a nonempty input as an empty container.
private func emptyContainer<Value>(_ value: Value, matches: @escaping (Value) -> Bool) -> AnyGenerator {
    Gen.comap(
        { (input: Value) -> Value? in matches(input) ? .some(input) : nil },
        Gen.just(value)
    ).erase()
}
