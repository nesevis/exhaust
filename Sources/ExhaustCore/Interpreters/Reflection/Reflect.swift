//
//  Reflect.swift
//  Exhaust
//
//  Created by Chris Kolbu on 16/7/2025.
//

import Foundation

// MARK: - Academic Background

//
// Implements the `reflect` interpretation (Goldstein section 4.3.3, Fig 4.4). Backward pass that extracts choice sequences from concrete values by trying all possible decompositions. Exhaust extends reflection to handle six additional operations not in the dissertation: sequence, zip, just, filter, classify, and unique.

extension Interpreters {
    // MARK: - Public-Facing Reflect Function

    /// Finds the choice sequence that would cause `gen` to produce `outputValue`, performing the backward pass of the generator interpretation.
    ///
    /// Reflection is the inverse of the forward generation pass: given a concrete output value and a generator, it walks the generator structure in reverse to reconstruct the ``ChoiceTree`` whose forward interpretation would produce that value. Returns `nil` when the value cannot be decomposed through the generator's structure (for example, when a contramap backward function rejects the value). The optional `check` closure filters results to only those whose output satisfies an additional predicate.
    ///
    /// - Parameters:
    ///   - gen: The generator to reflect through.
    ///   - outputValue: The target value to decompose into choices.
    ///   - check: An optional predicate that the reflected output must satisfy. Defaults to accepting all values.
    /// - Returns: A ``ChoiceTree`` encoding the choices that produce `outputValue`, or `nil` if no valid decomposition exists.
    /// - Throws: ``ReflectionError`` when the value is structurally incompatible with the generator or falls outside an explicit choice range.
    public static func reflect<Output>(
        _ gen: Generator<Output>,
        with outputValue: Output,
        // Optional validation check
        where check: (Output) -> Bool = { _ in true }
    ) throws -> ChoiceTree? {
        // The public API doesn't need to change. We start the process here.
        // We only care about the final output of the generator for the check.
        let allPossibleOutcomes = try reflectRecursive(gen, onFinalOutput: outputValue, context: .root)

        let matchingPaths = allPossibleOutcomes.compactMap { outputValue, path -> [ChoiceTree]? in
            return check(outputValue) ? path : nil
        }.flatMap { $0 }

        switch matchingPaths.count {
            case 0:
                return nil
            case 1:
                return matchingPaths[0]
            default:
                return .group(matchingPaths)
        }
    }

    // MARK: - Component-Replacing Reflection

    /// Reflects `parent` through a zip-shaped generator with one component swapped, returning the choice tree that produces the modified value, or nil when `gen` is not a zip-shaped reflective generator or the swap cannot be reflected.
    ///
    /// A composite built by `#gen(a, b, c) { Foo(a, b, c) }` reflects as `contramap*→zip`. The map adds no choices, so the zip's component subtrees are the whole choice tree. Recovering the parent's component tuple, replacing component `index`, and reflecting the zip against the modified tuple yields the sequence that materializes to `Foo` with that field retargeted and the rest preserved. The value type is never reconstructed: `Mirror` is read-only, so the `[Any]` component tuple is the only generically mutable representation, which is why the swap happens there rather than on the value.
    ///
    /// - Parameters:
    ///   - gen: A zip-shaped reflective generator (`contramap*→zip`); any other shape returns nil.
    ///   - parent: The scaffold value supplying every component but the replaced one.
    ///   - index: The component to replace.
    ///   - replacement: Given the parent's component, whose runtime type is the field type, returns its replacement or nil to reject the graft.
    /// - Returns: The choice tree for the modified value, or nil on any miss.
    package static func reflectReplacingZipComponent<Output>(
        _ gen: Generator<Output>,
        parent: Output,
        index: Int,
        replacement: (Any) -> Any?
    ) throws -> ChoiceTree? {
        guard let (children, components) = locateZip(gen.erase(), value: parent) else {
            return nil
        }
        guard components.indices.contains(index),
              let newComponent = replacement(components[index])
        else {
            return nil
        }
        var modified = components
        modified[index] = newComponent
        let results = try reflectZipOperation(generators: children, finalOutput: modified, context: .root)
        guard let path = results.first?.path, path.count == 1 else {
            return nil
        }
        return path[0]
    }

    /// Grafts a harvested comparison operand into one field of `parent` and reflects the retargeted composite, or nil when the field cannot take the operand.
    ///
    /// Composes ``reflectReplacingZipComponent(_:parent:index:replacement:)`` with the reconstructor selected from the field's runtime type: the operand's bytes are decoded as the field's own type through ``OperandReconstruction/erasedReconstructor(for:)``, so no per-type closure is written and the whole path is driven by the operand word alone. This is the decision the injection loop makes for one draw; keeping it here, rather than inline in the runner, lets it be exercised with a literal operand word standing in for the trace-cmp comparand.
    ///
    /// - Parameters:
    ///   - gen: A zip-shaped reflective generator (`contramap*→zip`).
    ///   - parent: The scaffold value supplying every field but the grafted one.
    ///   - index: The field to retarget.
    ///   - operand: The harvested comparison operand.
    /// - Returns: The choice tree for the retargeted value, or nil on any miss.
    package static func reflectGraftingOperand<Output>(
        into gen: Generator<Output>,
        parent: Output,
        index: Int,
        operand: UInt64
    ) throws -> ChoiceTree? {
        try reflectReplacingZipComponent(gen, parent: parent, index: index) { component in
            guard let reconstruct = OperandReconstruction.erasedReconstructor(for: type(of: component)) else {
                return nil
            }
            return reconstruct(operand)
        }
    }

    /// Whether `gen` is a zip-shaped generator the field graft can target: a `zip` reachable through only the choice-free, invertible wrappers (`contramap`, `prune`, and the `isomorph` or bidirectional-`map` `transform`). Structural only — it does not apply the backward transforms, so it needs no value and is meant to be computed once at construction to gate the graft, sparing a non-composite generator the parent materialization the graft would otherwise run before discovering it cannot reflect.
    package static func isZipShaped(_ gen: Generator<some Any>) -> Bool {
        structurallyReachesZip(gen.erase())
    }

    private static func structurallyReachesZip(_ gen: AnyGenerator) -> Bool {
        guard case let .impure(operation, _) = gen else {
            return false
        }
        switch operation {
            case let .contramap(_, next):
                return structurallyReachesZip(next)
            case let .prune(next):
                return structurallyReachesZip(next)
            case let .transform(kind, inner):
                switch kind {
                    case .isomorph:
                        return structurallyReachesZip(inner)
                    case let .map(_, backward, _, _):
                        return backward != nil && structurallyReachesZip(inner)
                    default:
                        return false
                }
            case .zip:
                return true
            default:
                return false
        }
    }

    /// Descends the choice-free layers wrapping a `zip` — `contramap`, `prune`, and the invertible `transform` (`isomorph` and bidirectional `map`) that `Gen.zip` and an initializer-shaped `#gen` emit — to the zip itself, applying each layer's backward function to `value` so the returned tuple is the zip's own `[Any]` input. `Gen.zip` wraps its `[Any]` payload in an `isomorph`; a `#gen(a, b, c) { Foo(...) }` adds a bidirectional `map` above that, so a struct reaches the zip through two transform layers. Returns nil at a forward-only `map`, any other operation, a `.pure` terminal, or when a backward function rejects the value.
    private static func locateZip(
        _ gen: AnyGenerator,
        value: Any
    ) -> (children: ContiguousArray<AnyGenerator>, components: [Any])? {
        guard case let .impure(operation, _) = gen else {
            return nil
        }
        switch operation {
            case let .contramap(transform, next):
                guard let narrowed = try? transform(value) else {
                    return nil
                }
                return locateZip(next, value: narrowed)
            case let .prune(next):
                return locateZip(next, value: value)
            case let .transform(kind, inner):
                switch kind {
                    case let .isomorph(_, backward, _, _):
                        guard let innerValue = try? backward(value) else {
                            return nil
                        }
                        return locateZip(inner, value: innerValue)
                    case let .map(_, backward?, _, _):
                        guard let innerValue = try? backward(value) else {
                            return nil
                        }
                        return locateZip(inner, value: innerValue)
                    default:
                        return nil
                }
            case let .zip(generators, _):
                guard let components = value as? [Any], components.count == generators.count else {
                    return nil
                }
                return (generators, components)
            default:
                return nil
        }
    }

    // MARK: - Recursive Engine

    /// Reflects a target output value backward through a generator, reconstructing the choice tree path that produces it.
    ///
    /// Walks the ``FreerMonad`` spine in reverse: for `.pure`, returns the value directly; for `.impure`, calls ``interpretOperationBackward(_:onFinalOutput:context:)`` to determine which intermediate values could have produced the target, then recurses through the continuation for each candidate. The `finalOutput` is threaded unchanged through the entire recursion — each operation extracts its own intermediate from it.
    ///
    /// ``ReflectionContext`` carries the scopes an operation forwards unchanged. Recursive value passing restores an outer scope when a nested call returns, so no operation has to undo one.
    ///
    /// - Returns: The reflected value and its path when the generator can produce `finalOutput`, or an empty array when it cannot.
    static func reflectRecursive<Output>(
        _ gen: Generator<Output>,
        onFinalOutput finalOutput: Any,
        context: ReflectionContext
    ) throws -> [(value: Output, path: [ChoiceTree])] {
        switch gen {
            case let .pure(value):
                // The pure value is the result for this path. No check needed here.
                return [(value, [])]

            case let .impure(operation, continuation):
                // 1. Interpret the operation against the final output value.
                let intermediateResults = try interpretOperationBackward(operation, onFinalOutput: finalOutput, context: context)

                // 2. For each successful intermediate result...
                return try intermediateResults.flatMap { (intermediateValue: Any, partialPath: [ChoiceTree]) in
                    let nextGen = try continuation(intermediateValue)
                    // The `finalOutput` is passed down UNCHANGED. This is the crucial part.
                    let finalResults = try reflectRecursive(nextGen, onFinalOutput: finalOutput, context: context)
                    return finalResults.compactMap { finalValue, restOfPath in
                        (finalValue as? Output).map { (value: $0, path: partialPath + restOfPath) }
                    }
                }
        }
    }
}
