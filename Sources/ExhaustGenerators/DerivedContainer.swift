import ExhaustCore

/// Describes a standard container without resolving or constructing its contents.
///
/// The derivation plan resolves every child through its own override and default rules. At a depth where any child is unavailable, the empty generator supplies a terminating value without requesting a generator at a negative depth.
package protocol DerivedContainer {
    static var derivationRecipe: DerivedContainerRecipe { get }
}

/// How many elements one built container layer may hold.
package enum ContainerCardinality {
    /// The container factory's own size-scaled count, used when neither a node allowance nor a bounded state space applies.
    case sizeScaled

    /// Sampled within `0 ... maximum`, leaving larger counts reflectable so a value that arrives through `reflecting:` still decomposes.
    case within(Int)

    /// Exactly this many elements, rejecting every other count.
    ///
    /// The strictness is what lets ``DerivedContainerRecipe/selectCount`` tell its prebuilt layers apart: reflecting a three-element value has to fail against the two-element layer for the selector to land on the three-element one.
    case exactly(Int)
}

/// Separates the empty construction, the counted construction, and the layer selection. Child order matches the factory's positional inputs, including key before value for dictionaries. Budgeted layers share completed child generators across every entry, not their node allowance.
package struct DerivedContainerRecipe {
    let type: Any.Type
    let childTypes: [Any.Type]

    /// The container's own structural ceiling, independent of any node allowance. `Optional` holds at most one element; the rest are unbounded.
    let maximumCount: Int?

    /// Matches the public container factory; deduplicating containers do not promise reflection even when their elements do.
    let isReflective: Bool

    /// Produces only the container's empty value, and rejects a nonempty reflection target rather than replaying it as empty.
    let empty: AnyGenerator

    /// Builds one layer at the given cardinality.
    let build: (ContainerCardinality, [AnyGenerator]) -> AnyGenerator

    /// Samples through the given cardinality while retaining every prebuilt layer for reflection. The value's own count recovers the layer without generation state.
    let selectCount: (Int, [AnyGenerator]) -> AnyGenerator
}

// MARK: - Conformances

extension Array: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        .sequence(
            Self.self,
            element: Element.self,
            isReflective: true,
            empty: Self(),
            isEmpty: { $0.isEmpty },
            count: { $0.count },
            build: { element, lengths in Gen.arrayOf(element, lengths) }
        )
    }
}

extension Set: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        .sequence(
            Self.self,
            element: Element.self,
            isReflective: false,
            empty: Self(),
            isEmpty: { $0.isEmpty },
            count: { $0.count },
            build: { element, lengths in Gen.setOf(element, lengths) }
        )
    }
}

extension Dictionary: DerivedContainer {
    package static var derivationRecipe: DerivedContainerRecipe {
        .keyed(
            Self.self,
            key: Key.self,
            value: Value.self,
            isReflective: false,
            empty: Self(),
            isEmpty: { $0.isEmpty },
            count: { $0.count },
            build: { key, value, counts in Gen.dictionaryOf(key, value, counts) }
        )
    }
}

/// Written out rather than built from ``DerivedContainerRecipe/sequence(_:element:isReflective:empty:isEmpty:count:build:)`` because presence is not a cardinality draw: ``ReflectiveGenerator/optional(_:)`` picks between the two shapes itself, so there is no length generator to hand it.
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
            build: { cardinality, children in
                let wrapped: Generator<Wrapped> = children.typed(0)
                switch cardinality {
                    case .sizeScaled, .within:
                        return ReflectiveGenerator<Wrapped>
                            .optional(wrapped.wrapped(isReflective: true))
                            .gen
                            .erase()
                    case .exactly:
                        // `maximumCount` caps the selector at one element, so the only exact layer it asks for is the present one.
                        return wrapped.liftToOptional().erase()
                }
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

// MARK: - Recipe Builders

package extension DerivedContainerRecipe {
    /// A container of one element type whose count comes from a length generator.
    ///
    /// The `build` closure receives an element generator already restored to `Element`, so a conformance never writes a cast of its own.
    static func sequence<Container, Element>(
        _ type: Container.Type,
        element _: Element.Type,
        isReflective: Bool,
        empty: Container,
        isEmpty: @escaping (Container) -> Bool,
        count: @escaping (Container) -> Int,
        build: @escaping (Generator<Element>, Generator<UInt64>?) -> Generator<Container>
    ) -> Self {
        Self(
            type: type,
            childTypes: [Element.self],
            maximumCount: nil,
            isReflective: isReflective,
            empty: emptyContainer(empty, matches: isEmpty),
            build: { cardinality, children in
                build(children.typed(0), cardinality.lengths).erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(layers, maximumGeneratedCount: maximumGeneratedCount, count: count)
            }
        )
    }

    /// A container of key and value types whose entry count comes from a length generator.
    static func keyed<Container, Key, Value>(
        _ type: Container.Type,
        key _: Key.Type,
        value _: Value.Type,
        isReflective: Bool,
        empty: Container,
        isEmpty: @escaping (Container) -> Bool,
        count: @escaping (Container) -> Int,
        build: @escaping (Generator<Key>, Generator<Value>, Generator<UInt64>?) -> Generator<Container>
    ) -> Self {
        Self(
            type: type,
            childTypes: [Key.self, Value.self],
            maximumCount: nil,
            isReflective: isReflective,
            empty: emptyContainer(empty, matches: isEmpty),
            build: { cardinality, children in
                build(children.typed(0), children.typed(1), cardinality.lengths).erase()
            },
            selectCount: { maximumGeneratedCount, layers in
                boundedContainer(layers, maximumGeneratedCount: maximumGeneratedCount, count: count)
            }
        )
    }
}

// MARK: - Helpers

extension ContainerCardinality {
    /// The length generator this policy asks a container factory for. A `nil` generator leaves the factory's own size scaling in place.
    var lengths: Generator<UInt64>? {
        switch self {
            case .sizeScaled:
                nil
            case let .within(maximum):
                derivedLengths(upTo: maximum)
            case let .exactly(count):
                Gen.choose(in: UInt64(count) ... UInt64(count))
        }
    }
}

extension [AnyGenerator] {
    /// Restores a child generator's payload type.
    ///
    /// The cast is safe wherever the recipe that captured this closure named the same types in `childTypes`, which is what the plan resolves children against. Keeping it here means a container conformance states its element types once instead of re-casting in every closure.
    func typed<Child>(_ index: Int) -> Generator<Child> {
        self[index].map { $0 as! Child }
    }
}

/// Samples a cardinality in `0 ... maximum` while leaving larger cardinalities reflectable.
///
/// A state space or node ceiling narrows what the derivation generates, not what a test can reduce from, so a value that arrives through `reflecting:` with more elements than this ceiling still decomposes.
func derivedLengths(upTo maximum: Int) -> Generator<UInt64> {
    Gen.chooseDerived(in: UInt64(0) ... UInt64(maximum), scaling: .linear)
}

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
