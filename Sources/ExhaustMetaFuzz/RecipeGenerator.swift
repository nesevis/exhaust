//
//  RecipeGenerator.swift
//  ExhaustMetaFuzz
//
//  Generates well-typed random GenRecipe values using Exhaust's own generators.
//

import ExhaustCore

// MARK: - Recipe Generator

/// Generates well-typed `GenRecipe` values using Exhaust's own generators.
///
/// Type-directed: only produces recipes whose output matches `type`.
/// Depth-bounded: at depth 0, only leaf generators are produced.
package func recipeGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    if maxDepth <= 0 {
        return leafGenerator(producing: type)
    }

    var choices: [(Int, Generator<GenRecipe>)] = [
        (3, leafGenerator(producing: type)),
        (1, mappedGenerator(producing: type, maxDepth: maxDepth)),
        (1, prunedGenerator(producing: type, maxDepth: maxDepth)),
        (1, arrayGenerator(producing: type, maxDepth: maxDepth)),
        (1, oneOfGenerator(producing: type, maxDepth: maxDepth)),
        (1, weightedOneOfGenerator(producing: type, maxDepth: maxDepth)),
        (1, filteredGenerator(producing: type, maxDepth: maxDepth)),
        (1, resizedGenerator(producing: type, maxDepth: maxDepth)),
        (1, optionalGenerator(producing: type, maxDepth: maxDepth)),
        (1, recursiveGenerator(producing: type, maxDepth: maxDepth)),
        (1, uniqueGenerator(producing: type, maxDepth: maxDepth)),
        (1, classifiedGenerator(producing: type, maxDepth: maxDepth)),
        (1, reifiedBindGenerator(producing: type, maxDepth: maxDepth)),
    ]
    if type == .int {
        choices.append((1, boundRangeGenerator(maxDepth: maxDepth)))
        choices.append((1, unfoldedGenerator()))
        choices.append((1, getSizedGenerator()))
    }
    if type == .int || type == .bool {
        choices.append((1, isomorphedGenerator(producing: type)))
    }
    if case .arrayOf = type {
        choices.append((1, boundArrayGenerator(producing: type, maxDepth: maxDepth)))
        choices.append((1, scaledArrayGenerator(producing: type, maxDepth: maxDepth)))
        choices.append((1, metamorphedGenerator(producing: type, maxDepth: maxDepth)))
        choices.append((1, zippedGenerator(producing: type, maxDepth: maxDepth)))
    }
    return Gen.pick(choices: choices)
}

private func leafGenerator(producing type: RecipeType) -> Generator<GenRecipe> {
    switch type {
        case .int:
            Gen.pick(choices: [
                (3, intRangeLeaf()),
                (1, justIntLeaf()),
            ])
        case .bool:
            Gen.pick(choices: [
                (3, .pure(.leaf(.bool))),
                (1, Gen.choose(from: [true, false]).map { .leaf(.justBool($0)) }),
            ])
        case .double:
            Gen.pick(choices: [
                (3, doubleRangeLeaf()),
                (1, justDoubleLeaf()),
            ])
        case .string:
            stringLeaf()
        case .character:
            .pure(.leaf(.character))
        case .arrayOf(.int):
            Gen.pick(choices: [
                (2, arrayGenerator(producing: type, maxDepth: 1)),
                (1, justIntArrayLeaf()),
            ])
        case .arrayOf:
            // Arrays can't be leaves — fall through to an array combinator at depth 1
            arrayGenerator(producing: type, maxDepth: 1)
    }
}

private func intRangeLeaf() -> Generator<GenRecipe> {
    // Generate two bounds and sort them to form a valid range
    Gen.choose(in: -100 ... 100 as ClosedRange<Int>).bind { a in
        Gen.choose(in: -100 ... 100 as ClosedRange<Int>).map { b in
            let lo = min(a, b)
            let hi = max(a, b)
            return GenRecipe.leaf(.int(lo ... hi))
        }
    }
}

private func justIntLeaf() -> Generator<GenRecipe> {
    Gen.choose(in: -50 ... 50 as ClosedRange<Int>).map { .leaf(.justInt($0)) }
}

private func doubleRangeLeaf() -> Generator<GenRecipe> {
    // Generate two bounds and sort them to form a valid range. Guided materialisation deliberately lets float NaN and infinity bit patterns bypass range clamping (Materializer+Handlers), so a mutated fuzz case can deliver non-finite draws here; fold them to zero so every draw builds a valid recipe instead of trapping in the range constructor. Finite draws are unaffected.
    Gen.choose(in: -100.0 ... 100.0 as ClosedRange<Double>).bind { a in
        Gen.choose(in: -100.0 ... 100.0 as ClosedRange<Double>).map { b in
            let first = a.isFinite ? a : 0
            let second = b.isFinite ? b : 0
            return GenRecipe.leaf(.double(min(first, second) ... max(first, second)))
        }
    }
}

private func justDoubleLeaf() -> Generator<GenRecipe> {
    Gen.choose(in: -50.0 ... 50.0 as ClosedRange<Double>).map { .leaf(.justDouble($0)) }
}

private func stringLeaf() -> Generator<GenRecipe> {
    // Generate a length range for an ASCII string leaf.
    Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>).bind { lo in
        Gen.choose(in: lo ... (lo + 5)).map { hi in
            GenRecipe.leaf(.string(lo ... hi))
        }
    }
}

private func justIntArrayLeaf() -> Generator<GenRecipe> {
    Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>).bind { length in
        Gen.arrayOf(Gen.choose(in: -50 ... 50 as ClosedRange<Int>), exactly: length).map { .leaf(.justIntArray($0)) }
    }
}

/// A narrowing transform (negate/increment/not) does an unchecked `as! Int`/`as! Bool` on the inner value, which traps if the inner yields an Optional — and the `optional` combinator declares its bare element type while producing `Optional`. Restrict narrowing transforms to leaves, which never wrap their output; `.identity` is total over any value, so it keeps the full recipe.
private func narrowingSafeInnerGenerator(
    for transform: InvertibleTransform,
    producing type: RecipeType,
    maxDepth: Int
) -> Generator<GenRecipe> {
    let innerType = transform.applicableType ?? type
    if transform == .identity {
        return recipeGenerator(producing: innerType, maxDepth: maxDepth - 1)
    }
    return leafGenerator(producing: innerType)
}

private func mappedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    let transforms = InvertibleTransform.applicable(to: type)
    guard transforms.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: transforms).bind { transform in
        narrowingSafeInnerGenerator(for: transform, producing: type, maxDepth: maxDepth).map { inner in
            .combinator(.mapped(inner, transform))
        }
    }
}

private func prunedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
        .combinator(.pruned(inner))
    }
}

private func arrayGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>).bind { lo in
        Gen.choose(in: lo ... (lo + 4)).bind { hi in
            recipeGenerator(producing: elementType, maxDepth: maxDepth - 1).map { inner in
                GenRecipe.combinator(.array(inner, lengthRange: lo ... hi))
            }
        }
    }
}

private func oneOfGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    // Generate 2–3 sub-recipes all producing the same type
    Gen.choose(in: 2 ... 3 as ClosedRange<Int>).bind { count in
        let subGen = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
        return Gen.arrayOf(subGen, exactly: UInt64(count)).map { recipes in
            GenRecipe.combinator(.oneOf(recipes))
        }
    }
}

private func filteredGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    let predicates = KnownPredicate.applicable(to: type)
    guard predicates.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: predicates).bind { predicate in
        var innerGen = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
        // For .isPositive, constrain inner int ranges to include positive values
        if predicate == .isPositive {
            innerGen = constrainedIntLeafForPositive()
        }
        return innerGen.map { inner in
            .combinator(.filtered(inner, predicate))
        }
    }
}

private func constrainedIntLeafForPositive() -> Generator<GenRecipe> {
    // Ensure the range includes at least one positive value
    Gen.choose(in: 1 ... 100 as ClosedRange<Int>).bind { hi in
        Gen.choose(in: -50 ... hi).map { lo in
            GenRecipe.leaf(.int(lo ... hi))
        }
    }
}

private func resizedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    Gen.choose(in: 1 ... 50 as ClosedRange<UInt64>).bind { size in
        recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
            .combinator(.resized(inner, size: size))
        }
    }
}

private func zippedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    let subA = recipeGenerator(producing: elementType, maxDepth: maxDepth - 1)
    let subB = recipeGenerator(producing: elementType, maxDepth: maxDepth - 1)
    return Gen.zip(subA, subB).map { a, b in
        GenRecipe.combinator(.zipped(a, b))
    }
}

private func optionalGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
        .combinator(.optional(inner))
    }
}

private func boundArrayGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(in: 1 ... 5 as ClosedRange<UInt64>).bind { maxLength in
        recipeGenerator(producing: elementType, maxDepth: maxDepth - 1).map { elementRecipe in
            GenRecipe.combinator(.boundArray(element: elementRecipe, maxLength: maxLength))
        }
    }
}

private func recursiveGenerator(producing type: RecipeType, maxDepth _: Int) -> Generator<GenRecipe> {
    leafGenerator(producing: type).map { base in
        .combinator(.recursive(base: base, maxDepth: 2))
    }
}

private func weightedOneOfGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    Gen.choose(in: 2 ... 3 as ClosedRange<Int>).bind { count in
        let branchGen = Gen.zip(
            Gen.choose(in: 1 ... 5 as ClosedRange<UInt64>),
            recipeGenerator(producing: type, maxDepth: maxDepth - 1)
        ).map { weight, recipe in
            GenRecipe.WeightedBranch(weight: weight, recipe: recipe)
        }
        return Gen.arrayOf(branchGen, exactly: UInt64(count)).map { branches in
            GenRecipe.combinator(.weightedOneOf(branches))
        }
    }
}

private func uniqueGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
        .combinator(.unique(inner))
    }
}

private func classifiedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
        .combinator(.classified(inner))
    }
}

private func scaledArrayGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: GenRecipe.RecipeScaling.allCases).bind { scaling in
        Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>).bind { lo in
            Gen.choose(in: lo ... (lo + 4)).bind { hi in
                recipeGenerator(producing: elementType, maxDepth: maxDepth - 1).map { inner in
                    GenRecipe.combinator(.scaledArray(inner, lengthRange: lo ... hi, scaling: scaling))
                }
            }
        }
    }
}

private func metamorphedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    let transforms = InvertibleTransform.applicable(to: elementType)
    guard transforms.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: transforms).bind { transform in
        narrowingSafeInnerGenerator(for: transform, producing: elementType, maxDepth: maxDepth).map { inner in
            .combinator(.metamorphed(inner, transform))
        }
    }
}

private func unfoldedGenerator() -> Generator<GenRecipe> {
    Gen.choose(in: 0 ... 4 as ClosedRange<Int>).bind { lower in
        Gen.choose(in: lower ... (lower + 3)).map { upper in
            GenRecipe.combinator(.unfolded(depthRange: lower ... upper))
        }
    }
}

private func boundRangeGenerator(maxDepth _: Int) -> Generator<GenRecipe> {
    leafGenerator(producing: .int).map { inner in
        .combinator(.boundRange(inner))
    }
}

private func reifiedBindGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    recipeGenerator(producing: type, maxDepth: maxDepth - 1).map { inner in
        .combinator(.reifiedBind(inner))
    }
}

private func getSizedGenerator() -> Generator<GenRecipe> {
    .pure(.combinator(.getSized))
}

private func isomorphedGenerator(producing type: RecipeType) -> Generator<GenRecipe> {
    let transforms = InvertibleTransform.applicable(to: type).filter { $0 != .identity }
    guard transforms.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: transforms).bind { transform in
        narrowingSafeInnerGenerator(for: transform, producing: type, maxDepth: 1).map { inner in
            .combinator(.isomorphed(inner, transform))
        }
    }
}
