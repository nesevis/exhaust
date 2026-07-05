//
//  GenRecipe.swift
//  ExhaustTests
//
//  Defunctionalized FreerMonad recipes for meta-testing: generating random
//  generator *recipes*, interpreting them into real generators, and verifying
//  that invariants hold universally across all possible generator structures.
//

import ExhaustCore
import Testing

// MARK: - Recipe Type (output type tracking)

indirect enum RecipeType: Equatable, Hashable, Sendable, CustomStringConvertible {
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
            case .not: (value as! Bool) == false
        }
    }

    func backward(_ value: Any) -> Any {
        switch self {
            case .identity: value
            case .negate: -(value as! Int)
            case .increment: (value as! Int) - 1
            case .not: (value as! Bool) == false
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
            case .isPositive: (value as? Int).map { $0 > 0 } ?? false
            case .isEven: (value as? Int).map { $0 % 2 == 0 } ?? false
            case .isNonEmpty: (value as? [Any]).map { $0.isEmpty == false } ?? false
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
        case optional(GenRecipe)
        case boundArray(element: GenRecipe, maxLength: UInt64)
        case boundRange(GenRecipe)
        case recursive(base: GenRecipe, maxDepth: UInt64)

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
                case let .optional(inner):
                    "\(inner)?"
                case let .boundArray(element: element, maxLength: maxLength):
                    "\(element).boundArray(maxLength: \(maxLength))"
                case let .boundRange(inner):
                    "\(inner).boundRange"
                case let .recursive(base: base, maxDepth: maxDepth):
                    "recursive(\(base), maxDepth: \(maxDepth))"
            }
        }
    }

    var description: String {
        switch self {
            case let .leaf(kind): kind.description
            case let .combinator(kind): kind.description
        }
    }

    /// Total number of recipe nodes. Interpreting a recipe recurses through fat ReflectiveOperation switch frames, and debug builds allocate all cases per frame, so the invariant harness budgets by node count rather than nesting depth alone.
    var nodeCount: Int {
        switch self {
            case .leaf:
                return 1
            case let .combinator(kind):
                switch kind {
                    case let .mapped(inner, _): return 1 + inner.nodeCount
                    case let .array(inner, lengthRange: _): return 1 + inner.nodeCount
                    case let .oneOf(recipes): return 1 + recipes.reduce(0) { $0 + $1.nodeCount }
                    case let .filtered(inner, _): return 1 + inner.nodeCount
                    case let .resized(inner, size: _): return 1 + inner.nodeCount
                    case let .zipped(a, b): return 1 + a.nodeCount + b.nodeCount
                    case let .optional(inner): return 1 + inner.nodeCount
                    case let .boundArray(element: element, maxLength: _): return 1 + element.nodeCount
                    case let .boundRange(inner): return 1 + inner.nodeCount
                    case let .recursive(base: base, maxDepth: _): return 1 + base.nodeCount
                }
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
                        return a.outputType
                    case let .optional(inner):
                        return inner.outputType
                    case let .boundArray(element: element, maxLength: _):
                        return .arrayOf(element.outputType)
                    case .boundRange:
                        return .int
                    case let .recursive(base: base, maxDepth: _):
                        return base.outputType
                }
        }
    }
}

// MARK: - Recipe Generator

/// Generates well-typed `GenRecipe` values using Exhaust's own generators.
///
/// Type-directed: only produces recipes whose output matches `type`.
/// Depth-bounded: at depth 0, only leaf generators are produced.
func recipeGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    if maxDepth <= 0 {
        return leafGenerator(producing: type)
    }

    var choices: [(Int, Generator<GenRecipe>)] = [
        (3, leafGenerator(producing: type)),
        (1, mappedGenerator(producing: type, maxDepth: maxDepth)),
        (1, arrayGenerator(producing: type, maxDepth: maxDepth)),
        (1, oneOfGenerator(producing: type, maxDepth: maxDepth)),
        (1, filteredGenerator(producing: type, maxDepth: maxDepth)),
        (1, resizedGenerator(producing: type, maxDepth: maxDepth)),
        (1, zippedGenerator(producing: type, maxDepth: maxDepth)),
        (1, optionalGenerator(producing: type, maxDepth: maxDepth)),
        (1, recursiveGenerator(producing: type, maxDepth: maxDepth)),
    ]
    if type == .int {
        choices.append((1, boundRangeGenerator(maxDepth: maxDepth)))
    }
    if case .arrayOf = type {
        choices.append((1, boundArrayGenerator(producing: type, maxDepth: maxDepth)))
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

private func justIntArrayLeaf() -> Generator<GenRecipe> {
    Gen.choose(in: 0 ... 3 as ClosedRange<UInt64>).bind { length in
        Gen.arrayOf(Gen.choose(in: -50 ... 50 as ClosedRange<Int>), exactly: length).map { .leaf(.justIntArray($0)) }
    }
}

private func mappedGenerator(producing type: RecipeType, maxDepth: Int) -> Generator<GenRecipe> {
    let transforms = InvertibleTransform.applicable(to: type)
    guard transforms.isEmpty == false else {
        return leafGenerator(producing: type)
    }
    return Gen.choose(from: transforms).bind { transform in
        // The inner recipe must produce a type compatible with the transform
        let innerType = transform.applicableType ?? type
        return recipeGenerator(producing: innerType, maxDepth: maxDepth - 1).map { inner in
            .combinator(.mapped(inner, transform))
        }
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
    let subA = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
    let subB = recipeGenerator(producing: type, maxDepth: maxDepth - 1)
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

private func boundRangeGenerator(maxDepth _: Int) -> Generator<GenRecipe> {
    leafGenerator(producing: .int).map { inner in
        .combinator(.boundRange(inner))
    }
}

// MARK: - Recipe Interpreter

/// Builds a real `AnyGenerator` from a `GenRecipe`.
func buildGenerator(
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
        case let .justInt(value):
            Gen.just(value).erase()
        case let .justBool(value):
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
        case let .mapped(inner, transform):
            return Gen.contramap(
                { (newOutput: Any) throws -> Any in transform.backward(newOutput) },
                buildGenerator(from: inner).map { transform.forward($0) }
            )

        case let .array(inner, lengthRange: range):
            return Gen.arrayOf(buildGenerator(from: inner), within: range).erase()

        case let .oneOf(recipes):
            return Gen.pick(choices: recipes.map { (1, buildGenerator(from: $0)) })

        case let .filtered(inner, predicate):
            let innerGen = buildGenerator(from: inner)
            return AnyGenerator.impure(
                operation: .filter(
                    gen: innerGen.erase(),
                    fingerprint: Gen.sourceFingerprint(fileID: fileID, line: line, column: column),
                    filterType: .auto,
                    predicate: { predicate.evaluate($0) },
                    sourceLocation: FilterSourceLocation(fileID: fileID, filePath: filePath, line: column, column: column)
                ),
                continuation: { .pure($0) }
            )

        case let .resized(inner, size: size):
            return Gen.resize(size, buildGenerator(from: inner))

        case let .zipped(a, b):
            return Gen.zip(buildGenerator(from: a), buildGenerator(from: b)).map { first, _ in first }

        case let .optional(inner):
            let innerGen = buildGenerator(from: inner)
            return Gen.pick(choices: [
                (1, Gen.just(Any?.none as Any)),
                (5, innerGen.map { Any?.some($0) as Any }),
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
    }
}

// MARK: - Any Equality Helper

/// Compares two `Any` values for equality.
///
/// Uses `isEqualToAny` for `Equatable` types, falls back to element-wise
/// comparison for `[Any]`.
func anyEquals(_ lhs: Any, _ rhs: Any) -> Bool {
    let lhsMirror = Mirror(reflecting: lhs)
    let rhsMirror = Mirror(reflecting: rhs)
    let lhsIsOptional = lhsMirror.displayStyle == .optional
    let rhsIsOptional = rhsMirror.displayStyle == .optional
    if lhsIsOptional || rhsIsOptional {
        let lhsHasValue = lhsIsOptional ? lhsMirror.children.first != nil : true
        let rhsHasValue = rhsIsOptional ? rhsMirror.children.first != nil : true
        if lhsHasValue == false && rhsHasValue == false { return true }
        if lhsHasValue == false || rhsHasValue == false { return false }
        let lhsInner: Any = lhsIsOptional ? lhsMirror.children.first!.value : lhs
        let rhsInner: Any = rhsIsOptional ? rhsMirror.children.first!.value : rhs
        return anyEquals(lhsInner, rhsInner)
    }

    // Try Equatable comparison
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
