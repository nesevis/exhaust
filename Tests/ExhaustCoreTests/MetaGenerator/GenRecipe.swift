//
//  GenRecipe.swift
//  ExhaustTests
//
//  Defunctionalized FreerMonad recipes for meta-testing: generating random
//  generator *recipes*, interpreting them into real generators, and verifying
//  that invariants hold universally across all possible generator structures.
//

import Testing
@testable import ExhaustCore

// MARK: - Recipe Type (output type tracking)

indirect enum RecipeType: Equatable, Hashable, CustomStringConvertible {
    case int
    case bool
    case arrayOf(RecipeType)

    var description: String {
        switch self {
        case .int: "Int"
        case .bool: "Bool"
        case let .arrayOf(element): "[\(element)]"
        }
    }
}

// MARK: - Invertible Transform

enum InvertibleTransform: String, Equatable, Hashable, CaseIterable {
    case identity
    case negate
    case increment
    case not

    var applicableType: RecipeType? {
        switch self {
        case .identity: nil
        case .negate, .increment: .int
        case .not: .bool
        }
    }

    func forward(_ value: Any) -> Any {
        switch self {
        case .identity: value
        case .negate: -(value as! Int)
        case .increment: (value as! Int) + 1
        case .not: !(value as! Bool)
        }
    }

    func backward(_ value: Any) -> Any {
        switch self {
        case .identity: value
        case .negate: -(value as! Int)
        case .increment: (value as! Int) - 1
        case .not: !(value as! Bool)
        }
    }

    static func applicable(to type: RecipeType) -> [InvertibleTransform] {
        allCases.filter { t in
            t.applicableType == nil || t.applicableType == type
        }
    }
}

// MARK: - Known Predicate

enum KnownPredicate: String, Equatable, Hashable, CaseIterable {
    case always
    case isPositive
    case isEven
    case isNonEmpty

    var applicableType: RecipeType? {
        switch self {
        case .always: nil
        case .isPositive, .isEven: .int
        case .isNonEmpty: nil
        }
    }

    func isApplicable(to type: RecipeType) -> Bool {
        switch self {
        case .always: return true
        case .isPositive, .isEven: return type == .int
        case .isNonEmpty:
            if case .arrayOf = type { return true }
            return false
        }
    }

    func evaluate(_ value: Any) -> Bool {
        switch self {
        case .always: true
        case .isPositive: (value as! Int) > 0
        case .isEven: (value as! Int) % 2 == 0
        case .isNonEmpty: !(value as! [Any]).isEmpty
        }
    }

    static func applicable(to type: RecipeType) -> [KnownPredicate] {
        allCases.filter { $0.isApplicable(to: type) }
    }
}

// MARK: - GenRecipe

/// A defunctionalized representation of `Free CombinatorOp LeafKind`.
///
/// The two-case structure mirrors `FreerMonad.pure` / `FreerMonad.impure`:
/// - `.leaf` corresponds to `.pure` — a terminal generator with no further composition
/// - `.combinator` corresponds to `.impure` — a combinator applied to sub-recipes
///
/// Unlike `FreerMonad`, recipes use data (not closures) for continuations, enabling
/// `Equatable` / `Hashable` conformance for structural comparison.
indirect enum GenRecipe: Equatable, Hashable, CustomStringConvertible {
    case leaf(LeafKind)
    case combinator(CombinatorKind)

    enum LeafKind: Equatable, Hashable, CustomStringConvertible {
        case int(ClosedRange<Int>)
        case bool
        case justInt(Int)
        case justBool(Bool)
        case justIntArray([Int])

        var description: String {
            switch self {
            case let .int(range): "int(\(range))"
            case .bool: "bool"
            case let .justInt(v): "just(\(v))"
            case let .justBool(v): "just(\(v))"
            case let .justIntArray(v): "just(\(v))"
            }
        }

        var outputType: RecipeType {
            switch self {
            case .int, .justInt: .int
            case .bool, .justBool: .bool
            case .justIntArray: .arrayOf(.int)
            }
        }
    }

    enum CombinatorKind: Equatable, Hashable, CustomStringConvertible {
        case mapped(GenRecipe, InvertibleTransform)
        case array(GenRecipe, lengthRange: ClosedRange<UInt64>)
        case oneOf([GenRecipe])
        case filtered(GenRecipe, KnownPredicate)
        case resized(GenRecipe, size: UInt64)
        case zipped(GenRecipe, GenRecipe)

        var description: String {
            switch self {
            case let .mapped(inner, transform):
                "\(inner).map(\(transform))"
            case let .array(inner, lengthRange: range):
                "\(inner).array(\(range))"
            case let .oneOf(recipes):
                "oneOf(\(recipes.map(\.description).joined(separator: ", ")))"
            case let .filtered(inner, predicate):
                "\(inner).filter(\(predicate))"
            case let .resized(inner, size: size):
                "resize(\(size), \(inner))"
            case let .zipped(a, b):
                "zip(\(a), \(b))"
            }
        }
    }

    var description: String {
        switch self {
        case let .leaf(kind): kind.description
        case let .combinator(kind): kind.description
        }
    }

    var outputType: RecipeType {
        switch self {
        case let .leaf(kind):
            return kind.outputType
        case let .combinator(kind):
            switch kind {
            case let .mapped(inner, transform):
                if let type = transform.applicableType {
                    return type
                }
                return inner.outputType
            case let .array(inner, lengthRange: _):
                return RecipeType.arrayOf(inner.outputType)
            case let .oneOf(recipes):
                return recipes[0].outputType
            case let .filtered(inner, _):
                return inner.outputType
            case let .resized(inner, size: _):
                return inner.outputType
            case let .zipped(a, _):
                // Zipped produces an array of the first recipe's type (both must match)
                return a.outputType
            }
        }
    }
}

// MARK: - Recipe Generator

/// Generates well-typed `GenRecipe` values using Exhaust's own generators.
///
/// Type-directed: only produces recipes whose output matches `type`.
/// Depth-bounded: at depth 0, only leaf generators are produced.
func recipeGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    if maxDepth <= 0 {
        return leafGenerator(producing: type)
    }

    return Gen.pick(choices: [
        (3, leafGenerator(producing: type)),
        (1, mappedGenerator(producing: type, maxDepth: maxDepth)),
        (1, arrayGenerator(producing: type, maxDepth: maxDepth)),
        (1, oneOfGenerator(producing: type, maxDepth: maxDepth)),
        (1, filteredGenerator(producing: type, maxDepth: maxDepth)),
        (1, resizedGenerator(producing: type, maxDepth: maxDepth)),
        (1, zippedGenerator(producing: type, maxDepth: maxDepth)),
    ])
}

private func leafGenerator(producing type: RecipeType) -> ReflectiveGenerator<GenRecipe> {
    switch type {
    case .int:
        Gen.pick(choices: [
            (3, intRangeLeaf()),
            (1, justIntLeaf()),
        ])
    case .bool:
        Gen.pick(choices: [
            (3, .pure(.leaf(.bool))),
            (1, Gen.choose(from: [true, false])._map { .leaf(.justBool($0)) }),
        ])
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

private func intRangeLeaf() -> ReflectiveGenerator<GenRecipe> {
    // Generate two bounds and sort them to form a valid range
    Gen.choose(in: -100 ... 100 as ClosedRange<Int>)._bind { a in
        Gen.choose(in: -100 ... 100 as ClosedRange<Int>)._map { b in
            let lo = min(a, b)
            let hi = max(a, b)
            return GenRecipe.leaf(.int(lo ... hi))
        }
    }
}

private func justIntLeaf() -> ReflectiveGenerator<GenRecipe> {
    Gen.choose(in: -50 ... 50 as ClosedRange<Int>)._map { .leaf(.justInt($0)) }
}

private func justIntArrayLeaf() -> ReflectiveGenerator<GenRecipe> {
    Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>)._bind { length in
        Gen.arrayOf(Gen.choose(in: -50 ... 50 as ClosedRange<Int>), exactly: length)._map { .leaf(.justIntArray($0)) }
    }
}

private func mappedGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    let transforms = InvertibleTransform.applicable(to: type)
    guard transforms.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: transforms)._bind { transform in
        // The inner recipe must produce a type compatible with the transform
        let innerType = transform.applicableType ?? type
        return recipeGenerator(producing: innerType, maxDepth: maxDepth - 1)._map { inner in
            .combinator(.mapped(inner, transform))
        }
    }
}

private func arrayGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    guard case let .arrayOf(elementType) = type else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>)._bind { lo in
        Gen.choose(in: lo ... (lo + 4))._bind { hi in
            recipeGenerator(producing: elementType, maxDepth: maxDepth - 1)._map { inner in
                GenRecipe.combinator(.array(inner, lengthRange: lo ... hi))
            }
        }
    }
}

private func oneOfGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    // Generate 2–3 sub-recipes all producing the same type
    Gen.choose(in: 2 ... 3 as ClosedRange<Int>)._bind { count in
        let subGen = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
        return Gen.arrayOf(subGen, exactly: UInt64(count))._map { recipes in
            GenRecipe.combinator(.oneOf(recipes))
        }
    }
}

private func filteredGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    let predicates = KnownPredicate.applicable(to: type)
    guard predicates.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: predicates)._bind { predicate in
        var innerGen = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
        // For .isPositive, constrain inner int ranges to include positive values
        if predicate == .isPositive {
            innerGen = constrainedIntLeafForPositive()
        }
        return innerGen._map { inner in
            .combinator(.filtered(inner, predicate))
        }
    }
}

private func constrainedIntLeafForPositive() -> ReflectiveGenerator<GenRecipe> {
    // Ensure the range includes at least one positive value
    Gen.choose(in: 1 ... 100 as ClosedRange<Int>)._bind { hi in
        Gen.choose(in: -50 ... hi)._map { lo in
            GenRecipe.leaf(.int(lo ... hi))
        }
    }
}

private func resizedGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    Gen.choose(in: 1 ... 50 as ClosedRange<UInt64>)._bind { size in
        recipeGenerator(producing: type, maxDepth: maxDepth - 1)._map { inner in
            .combinator(.resized(inner, size: size))
        }
    }
}

private func zippedGenerator(producing type: RecipeType, maxDepth: Int) -> ReflectiveGenerator<GenRecipe> {
    let subA = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
    let subB = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
    return Gen.zip(subA, subB)._map { a, b in
        GenRecipe.combinator(.zipped(a, b))
    }
}

// MARK: - Recipe Interpreter

/// Builds a real `ReflectiveGenerator<Any>` from a `GenRecipe`.
func buildGenerator(from recipe: GenRecipe) -> ReflectiveGenerator<Any> {
    switch recipe {
    case let .leaf(kind):
        buildLeaf(kind)
    case let .combinator(kind):
        buildCombinator(kind)
    }
}

private func buildLeaf(_ kind: GenRecipe.LeafKind) -> ReflectiveGenerator<Any> {
    switch kind {
    case let .int(range):
        Gen.choose(in: range).erase()
    case .bool:
        Gen.choose(from: [true, false]).erase()
    case let .justInt(value):
        Gen.just(value).erase()
    case let .justBool(value):
        Gen.just(value).erase()
    case let .justIntArray(value):
        Gen.just(value).erase()
    }
}

private func buildCombinator(_ kind: GenRecipe.CombinatorKind) -> ReflectiveGenerator<Any> {
    switch kind {
    case let .mapped(inner, transform):
        return Gen.contramap(
            { (newOutput: Any) throws -> Any in transform.backward(newOutput) },
            buildGenerator(from: inner)._map { transform.forward($0) }
        )

    case let .array(inner, lengthRange: range):
        return Gen.arrayOf(buildGenerator(from: inner), within: range).erase()

    case let .oneOf(recipes):
        return Gen.pick(choices: recipes.map { (1, buildGenerator(from: $0)) })

    case let .filtered(inner, predicate):
        let innerGen = buildGenerator(from: inner)
        return ReflectiveGenerator<Any>.impure(
            operation: .filter(gen: innerGen.erase(), fingerprint: 0, filterType: .auto, predicate: { predicate.evaluate($0) }),
            continuation: { .pure($0) }
        )

    case let .resized(inner, size: size):
        return Gen.resize(size, buildGenerator(from: inner))

    case let .zipped(a, b):
        // Zip produces a pair; we pick the first element to keep the output type consistent
        return Gen.zip(buildGenerator(from: a), buildGenerator(from: b))._map { first, _ in first }
    }
}

// MARK: - Any Equality Helper

/// Compares two `Any` values for equality.
///
/// Uses `isEqualToAny` for `Equatable` types, falls back to element-wise
/// comparison for `[Any]`.
func anyEquals(_ lhs: Any, _ rhs: Any) -> Bool {
    // Try Equatable comparison first
    if let lhsEq = lhs as? any Equatable {
        return lhsEq.isEqualToAny(rhs)
    }

    // Fall back to element-wise [Any] comparison
    if let lhsArray = lhs as? [Any], let rhsArray = rhs as? [Any] {
        guard lhsArray.count == rhsArray.count else { return false }
        return zip(lhsArray, rhsArray).allSatisfy { anyEquals($0, $1) }
    }

    return false
}
