//
//  RecipeBuilder.swift
//  ExhaustMetaFuzz
//
//  Interprets a GenRecipe into a real AnyGenerator, plus the failing properties and Any-equality helper the oracle roster shares.
//

import ExhaustCore
import Foundation

// MARK: - Recipe Interpreter

/// Builds a real `AnyGenerator` from a `GenRecipe`.
package func buildGenerator(
    from recipe: GenRecipe,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> AnyGenerator {
    switch recipe {
        case let .leaf(kind):
            buildLeaf(kind)
        case let .combinator(kind):
            buildCombinator(kind, fileID: fileID, filePath: filePath, line: line, column: column)
    }
}

private func buildLeaf(_ kind: GenRecipe.LeafKind) -> AnyGenerator {
    switch kind {
        case let .int(range):
            Gen.choose(in: range).erase()
        case .bool:
            Gen.choose(from: [true, false]).erase()
        case let .double(range):
            Gen.choose(in: range).erase()
        case let .string(range):
            asciiStringGen(length: range).erase()
        case .character:
            charGen(from: .decimalDigits).erase()
        case let .justInt(value):
            Gen.just(value).erase()
        case let .justBool(value):
            Gen.just(value).erase()
        case let .justDouble(value):
            Gen.just(value).erase()
        case let .justIntArray(value):
            Gen.just(value).erase()
    }
}

private func buildCombinator(
    _ kind: GenRecipe.CombinatorKind,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
) -> AnyGenerator {
    switch kind {
        case let .contramapped(inner, transform):
            return Gen.contramap(
                { (newOutput: Any) throws -> Any in transform.backward(newOutput) },
                buildGenerator(from: inner).map { transform.forward($0) }
            )

        case let .mapped(inner, transform):
            return ReflectiveGenerator(
                buildGenerator(from: inner)
            ).mapped(
                forward: { transform.forward($0) },
                backward: { transform.backward($0) }
            ).gen.erase()

        case let .pruned(inner):
            return Gen.prune(buildGenerator(from: inner))

        case let .array(inner, lengthRange: range):
            return Gen.arrayOf(buildGenerator(from: inner), within: range).erase()

        case let .oneOf(recipes):
            return Gen.pick(choices: recipes.map { (1, buildGenerator(from: $0)) })

        case let .filtered(inner, predicate):
            let innerGen = buildGenerator(from: inner)
            return AnyGenerator.impure(
                operation: .filter(
                    gen: innerGen.erase(),
                    fingerprint: recipeFingerprint(structure: "\(inner).filter(\(predicate))", fileID: fileID, line: line, column: column),
                    filterType: .auto,
                    predicate: { predicate.evaluate($0) },
                    sourceLocation: FilterSourceLocation(fileID: fileID, filePath: filePath, line: column, column: column)
                ),
                continuation: { .pure($0) }
            )

        case let .resized(inner, size: size):
            return Gen.resize(size, buildGenerator(from: inner))

        case let .zipped(a, b):
            // Keep the raw `.zip` output as `[first, second]` rather than projecting to one element. The `.zip` operation reflects structurally by decomposing the array into its children, so the whole pair round-trips; projecting to a single element produced a value the reflector could not decompose, silently voiding every zip round-trip assertion.
            return AnyGenerator.impure(
                operation: .zip([buildGenerator(from: a), buildGenerator(from: b)]),
                continuation: { .pure($0) }
            )

        case let .optional(inner):
            // Mirrors `liftToOptional()` in the type-erased world: the value branch's backward transform unwraps one optional layer and throws `reflectedNil` for nil, which `reflectPickOperation` treats as "this value belongs to the other branch". A plain forward-only `.map` here makes any nil-bearing nested optional unreflectable.
            let innerGen = buildGenerator(from: inner)
            let someBranch = AnyGenerator.impure(
                operation: .contramap(
                    transform: { result in
                        let mirror = Mirror(reflecting: result)
                        guard mirror.displayStyle == .optional else {
                            return result
                        }
                        guard let child = mirror.children.first else {
                            throw ReflectionError.reflectedNil(
                                type: "Any",
                                resultType: String(describing: type(of: result))
                            )
                        }
                        return child.value
                    },
                    next: innerGen
                ),
                continuation: { .pure(Any?.some($0) as Any) }
            )
            return Gen.pick(choices: [
                (1, Gen.just(Any?.none as Any)),
                (5, someBranch),
            ])

        case let .boundArray(element: element, maxLength: maxLength):
            let elementGen = buildGenerator(from: element)
            return Gen.choose(in: 0 ... maxLength).bind { length in
                Gen.arrayOf(elementGen, exactly: length).erase()
            }

        case let .boundRange(inner):
            let innerGen = buildGenerator(from: inner)
            return innerGen.bind { loAny in
                let lo = loAny as! Int
                let hi = lo + 50
                return Gen.choose(in: lo ... hi).map { $0 as Any }
            }

        case let .reifiedBind(inner):
            let innerGenerator = buildGenerator(from: inner)
            return AnyGenerator.impure(
                operation: .transform(
                    kind: .bind(
                        fingerprint: recipeFingerprint(
                            structure: "\(inner).reifiedBind",
                            fileID: fileID,
                            line: line,
                            column: column
                        ),
                        forward: { value in Gen.just(value).erase() },
                        backward: { $0 },
                        inputType: Any.self,
                        outputType: Any.self
                    ),
                    inner: innerGenerator
                ),
                continuation: { .pure($0) }
            )

        case let .recursive(base: base, maxDepth: maxDepth):
            let baseGen = buildGenerator(from: base)
            // The UInt64 depthRange selects the base-as-generator overload. An Int range would
            // resolve to the base-as-VALUE overload, and with Output == Any that traps the
            // generator itself as the base value.
            return Gen.recursive(base: baseGen, depthRange: 0 ... maxDepth) { recurse, remaining in
                Gen.pick(choices: [
                    (1, baseGen),
                    (Int(remaining), recurse().map(\.self)),
                ])
            }

        case let .weightedOneOf(branches):
            return Gen.pick(choices: branches.map { (weight: $0.weight, generator: buildGenerator(from: $0.recipe)) })

        case let .scaledArray(inner, lengthRange: range, scaling: scaling):
            return Gen.arrayOf(buildGenerator(from: inner), within: range, scaling: scaling.sizeScaling).erase()

        case let .unique(inner):
            // Choice-sequence deduplication (nil key extractor): works for any output type and exercises the sub-interpreter path in the value-only engine.
            return AnyGenerator.impure(
                operation: .unique(
                    gen: buildGenerator(from: inner).erase(),
                    fingerprint: recipeFingerprint(structure: "\(inner).unique", fileID: fileID, line: line, column: column),
                    keyExtractor: nil
                ),
                continuation: { .pure($0) }
            )

        case let .classified(inner):
            return Gen.classify(buildGenerator(from: inner), ("recipe", { _ in true }))

        case let .metamorphed(inner, transform):
            // Mirrors the raw metamorphic operation used by ReflectiveGenerator.metamorph: the value is [original, transformed copy], and reflection uses the original at position zero while preserving the component array for its continuation.
            return AnyGenerator.impure(
                operation: .transform(
                    kind: .metamorphic(
                        transforms: [{ transform.forward($0) }],
                        inputType: Any.self
                    ),
                    inner: buildGenerator(from: inner)
                ),
                continuation: { .pure($0) }
            )

        case let .unfolded(depthRange: depthRange):
            // A canonical integer accumulator: each step adds a drawn increment to the state, and finish returns the accumulated sum.
            return Gen.unfold(
                seed: Gen.just(0),
                depthRange: depthRange,
                step: { state, _ in
                    Gen.choose(in: 1 ... 3 as ClosedRange<Int>).map { UnfoldStep.recurse(state + $0) }
                },
                finish: { $0 }
            ).erase()

        case .getSized:
            // Reads the generation size and returns an explicitly bounded integer. getSize reflects by mapping the value back to size 100, whose 0...100 range contains every generated value.
            return Gen.getSize { size in
                Gen.choose(in: 0 ... Int(size))
            }.erase()

        case let .isomorphed(inner, transform):
            // Unlike `mapped` (a `contramap` wrapping a forward-only `.map`), `isomorph` is bidirectional by construction and must reflect without the contramap crutch. The transform is a genuine bijection; the inner is a leaf of the applicable type.
            let metatype: Any.Type = transform.applicableType == .bool ? Bool.self : Int.self
            return AnyGenerator.impure(
                operation: .transform(
                    kind: .isomorph(
                        forward: { transform.forward($0) },
                        backward: { transform.backward($0) },
                        inputType: metatype,
                        outputType: metatype
                    ),
                    inner: buildGenerator(from: inner)
                ),
                continuation: { .pure($0) }
            )
    }
}

/// A per-recipe fingerprint for filter and unique sites. One `buildCombinator` call site constructs every recipe of a kind, so a bare source fingerprint would give structurally different recipes one shared tuned-filter cache slot (handing one recipe's tuned generator to another) or one shared unique seen-set. Folding the recipe structure in models what distinct user call sites get, the same way `Gen.filterFingerprint` folds in the output type.
private func recipeFingerprint(structure: String, fileID: StaticString, line: UInt, column: UInt) -> UInt64 {
    var fingerprint = Gen.sourceFingerprint(fileID: fileID, line: line, column: column)
    for byte in structure.utf8 {
        fingerprint = Xoshiro256.fold(fingerprint, mixing: UInt64(byte))
    }
    return fingerprint
}

// MARK: - Failing Property

/// A property with a satisfiable failure condition for each recipe output type, so reduction has counterexamples to preserve. Values of unexpected types pass vacuously, matching the original int-only formulation.
package func failingProperty(for type: RecipeType) -> (Any) -> Bool {
    switch type {
        case .int:
            { value in (value as? Int).map { $0 < 10 } ?? true }
        case .bool:
            { value in (value as? Bool).map { $0 == false } ?? true }
        case .double:
            { value in (value as? Double).map { $0 < 10 } ?? true }
        case .string:
            { value in (value as? String).map { $0.count < 2 } ?? true }
        case .character:
            { value in (value as? Character).map { $0 == "0" } ?? true }
        case .arrayOf:
            { value in (value as? [Any]).map { $0.count < 2 } ?? true }
    }
}

// MARK: - Any Equality Helper

/// Compares two `Any` values for equality.
///
/// Uses `isEqualToAny` for `Equatable` types, falls back to element-wise
/// comparison for `[Any]`.
package func anyEquals(_ lhs: Any, _ rhs: Any) -> Bool {
    let lhsMirror = Mirror(reflecting: lhs)
    let rhsMirror = Mirror(reflecting: rhs)
    let lhsIsOptional = lhsMirror.displayStyle == .optional
    let rhsIsOptional = rhsMirror.displayStyle == .optional
    if lhsIsOptional || rhsIsOptional {
        let lhsHasValue = lhsIsOptional ? lhsMirror.children.first != nil : true
        let rhsHasValue = rhsIsOptional ? rhsMirror.children.first != nil : true
        if lhsHasValue == false && rhsHasValue == false {
            return true
        }
        if lhsHasValue == false || rhsHasValue == false {
            return false
        }
        let lhsInner: Any = lhsIsOptional ? lhsMirror.children.first!.value : lhs
        let rhsInner: Any = rhsIsOptional ? rhsMirror.children.first!.value : rhs
        return anyEquals(lhsInner, rhsInner)
    }

    // NaN compares unequal to itself under Equatable, but an exact round trip of a NaN bit pattern IS a faithful reproduction — mutated fuzz cases carry NaN through the pipeline (guided mode deliberately exempts non-finite floats from clamping), and the oracles must not report those round trips as violations.
    if let lhsDouble = lhs as? Double, let rhsDouble = rhs as? Double {
        return lhsDouble == rhsDouble || (lhsDouble.isNaN && rhsDouble.isNaN)
    }

    // Try Equatable comparison
    if let lhsEq = lhs as? any Equatable {
        return lhsEq.isEqualToAny(rhs)
    }

    // Fall back to element-wise [Any] comparison
    if let lhsArray = lhs as? [Any], let rhsArray = rhs as? [Any] {
        guard lhsArray.count == rhsArray.count else {
            return false
        }
        return zip(lhsArray, rhsArray).allSatisfy { anyEquals($0, $1) }
    }

    return false
}
