//
//  GenRecipe.swift
//  ExhaustMetaFuzz
//
//  Defunctionalized FreerMonad recipes for meta-testing: generating random generator *recipes*, interpreting them into real generators, and verifying that invariants hold universally across all possible generator structures.
//

import ExhaustCore

// MARK: - Recipe Type (output type tracking)

/// The output type a recipe produces, tracked so recipe generation stays well-typed.
package indirect enum RecipeType: Equatable, Hashable, Sendable, Codable, CustomStringConvertible {
    case int
    case bool
    case double
    case string
    case character
    case arrayOf(RecipeType)

    package var description: String {
        switch self {
            case .int:
                "Int"
            case .bool:
                "Bool"
            case .double:
                "Double"
            case .string:
                "String"
            case .character:
                "Character"
            case let .arrayOf(element):
                "[\(element)]"
        }
    }
}

// MARK: - Invertible Transform

/// A named bijection recipes can apply through `map`, `metamorph`, and `isomorph`, kept as data so recipes stay `Hashable` and the backward direction is always available.
package enum InvertibleTransform: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
    case identity
    case negate
    case increment
    case not

    package var applicableType: RecipeType? {
        switch self {
            case .identity:
                nil
            case .negate, .increment:
                .int
            case .not:
                .bool
        }
    }

    /// Applies the transform in the generation direction. The force casts encode the pairing rule ``applicableType`` states: recipe construction only attaches a narrowing transform to an inner recipe of exactly that type, so a mismatched value is a recipe-construction bug, not fuzz input.
    package func forward(_ value: Any) -> Any {
        switch self {
            case .identity:
                value
            case .negate:
                -(value as! Int)
            case .increment:
                (value as! Int) + 1
            case .not:
                (value as! Bool) == false
        }
    }

    /// Applies the inverse transform; see ``forward(_:)`` for the force-cast contract.
    package func backward(_ value: Any) -> Any {
        switch self {
            case .identity:
                value
            case .negate:
                -(value as! Int)
            case .increment:
                (value as! Int) - 1
            case .not:
                (value as! Bool) == false
        }
    }

    package static func applicable(to type: RecipeType) -> [InvertibleTransform] {
        allCases.filter { transform in
            transform.applicableType == nil || transform.applicableType == type
        }
    }
}

// MARK: - Known Predicate

/// A named filter predicate recipes can apply, kept as data so recipes stay `Hashable`.
package enum KnownPredicate: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
    case always
    case isPositive
    case isEven
    case isNonEmpty

    package var applicableType: RecipeType? {
        switch self {
            case .always:
                nil
            case .isPositive, .isEven:
                .int
            case .isNonEmpty:
                nil
        }
    }

    package func isApplicable(to type: RecipeType) -> Bool {
        switch self {
            case .always:
                return true
            case .isPositive, .isEven:
                return type == .int
            case .isNonEmpty:
                if case .arrayOf = type {
                    return true
                }
                return false
        }
    }

    package func evaluate(_ value: Any) -> Bool {
        switch self {
            case .always:
                true
            case .isPositive:
                (value as? Int).map { $0 > 0 } ?? false
            case .isEven:
                (value as? Int).map { $0 % 2 == 0 } ?? false
            case .isNonEmpty:
                (value as? [Any]).map { $0.isEmpty == false } ?? false
        }
    }

    package static func applicable(to type: RecipeType) -> [KnownPredicate] {
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
package indirect enum GenRecipe: Equatable, Hashable, CustomStringConvertible, Sendable, Codable {
    case leaf(LeafKind)
    case combinator(CombinatorKind)

    package enum LeafKind: Equatable, Hashable, CustomStringConvertible, Sendable, Codable {
        case int(ClosedRange<Int>)
        case bool
        case double(ClosedRange<Double>)
        case string(ClosedRange<UInt64>)
        case character
        case justInt(Int)
        case justBool(Bool)
        case justDouble(Double)
        case justIntArray([Int])

        package var description: String {
            switch self {
                case let .int(range):
                    "int(\(range))"
                case .bool:
                    "bool"
                case let .double(range):
                    "double(\(range))"
                case let .string(range):
                    "string(len: \(range))"
                case .character:
                    "char"
                case let .justInt(v):
                    "just(\(v))"
                case let .justBool(v):
                    "just(\(v))"
                case let .justDouble(v):
                    "just(\(v))"
                case let .justIntArray(v):
                    "just(\(v))"
            }
        }

        package var outputType: RecipeType {
            switch self {
                case .int, .justInt:
                    .int
                case .bool, .justBool:
                    .bool
                case .double, .justDouble:
                    .double
                case .string:
                    .string
                case .character:
                    .character
                case .justIntArray:
                    .arrayOf(.int)
            }
        }
    }

    /// One branch of a weighted pick recipe.
    package struct WeightedBranch: Equatable, Hashable, Sendable, Codable {
        package let weight: UInt64
        package let recipe: GenRecipe

        package init(weight: UInt64, recipe: GenRecipe) {
            self.weight = weight
            self.recipe = recipe
        }
    }

    /// Defunctionalized `SizeScaling` for scaled sequence recipes.
    package enum RecipeScaling: String, Equatable, Hashable, CaseIterable, Sendable, Codable {
        case constant
        case linear
        case exponential

        package var sizeScaling: SizeScaling<UInt64> {
            switch self {
                case .constant:
                    .constant
                case .linear:
                    .linear
                case .exponential:
                    .exponential
            }
        }
    }

    package enum CombinatorKind: Equatable, Hashable, CustomStringConvertible, Sendable, Codable {
        case mapped(GenRecipe, InvertibleTransform)
        case pruned(GenRecipe)
        case array(GenRecipe, lengthRange: ClosedRange<UInt64>)
        case oneOf([GenRecipe])
        case weightedOneOf([WeightedBranch])
        case filtered(GenRecipe, KnownPredicate)
        case resized(GenRecipe, size: UInt64)
        case zipped(GenRecipe, GenRecipe)
        case optional(GenRecipe)
        case boundArray(element: GenRecipe, maxLength: UInt64)
        case boundRange(GenRecipe)
        case reifiedBind(GenRecipe)
        case recursive(base: GenRecipe, maxDepth: UInt64)
        case scaledArray(GenRecipe, lengthRange: ClosedRange<UInt64>, scaling: RecipeScaling)
        case unique(GenRecipe)
        case classified(GenRecipe)
        case metamorphed(GenRecipe, InvertibleTransform)
        case unfolded(depthRange: ClosedRange<Int>)
        case getSized
        case isomorphed(GenRecipe, InvertibleTransform)

        package var description: String {
            switch self {
                case let .mapped(inner, transform):
                    "\(inner).map(\(transform))"
                case let .pruned(inner):
                    "prune(\(inner))"
                case let .array(inner, lengthRange: range):
                    "\(inner).array(\(range))"
                case let .oneOf(recipes):
                    "oneOf(\(recipes.map(\.description).joined(separator: ", ")))"
                case let .weightedOneOf(branches):
                    "weightedOneOf(\(branches.map { "\($0.weight): \($0.recipe)" }.joined(separator: ", ")))"
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
                case let .reifiedBind(inner):
                    "\(inner).reifiedBind"
                case let .recursive(base: base, maxDepth: maxDepth):
                    "recursive(\(base), maxDepth: \(maxDepth))"
                case let .scaledArray(inner, lengthRange: range, scaling: scaling):
                    "\(inner).array(\(range), scaling: .\(scaling.rawValue))"
                case let .unique(inner):
                    "\(inner).unique"
                case let .classified(inner):
                    "\(inner).classify"
                case let .metamorphed(inner, transform):
                    "\(inner).metamorph(\(transform))"
                case let .unfolded(depthRange: depthRange):
                    "unfold(\(depthRange))"
                case .getSized:
                    "getSize"
                case let .isomorphed(inner, transform):
                    "\(inner).isomorph(\(transform))"
            }
        }
    }

    package var description: String {
        switch self {
            case let .leaf(kind):
                kind.description
            case let .combinator(kind):
                kind.description
        }
    }

    /// Total number of recipe nodes. Interpreting a recipe recurses through fat ReflectiveOperation switch frames, and debug builds allocate all cases per frame, so the invariant harness budgets by node count rather than nesting depth alone.
    package var nodeCount: Int {
        switch self {
            case .leaf:
                return 1
            case let .combinator(kind):
                switch kind {
                    case let .mapped(inner, _):
                        return 1 + inner.nodeCount
                    case let .pruned(inner):
                        return 1 + inner.nodeCount
                    case let .array(inner, lengthRange: _):
                        return 1 + inner.nodeCount
                    case let .oneOf(recipes):
                        return 1 + recipes.reduce(0) { $0 + $1.nodeCount }
                    case let .weightedOneOf(branches):
                        return 1 + branches.reduce(0) { $0 + $1.recipe.nodeCount }
                    case let .filtered(inner, _):
                        return 1 + inner.nodeCount
                    case let .resized(inner, size: _):
                        return 1 + inner.nodeCount
                    case let .zipped(a, b):
                        return 1 + a.nodeCount + b.nodeCount
                    case let .optional(inner):
                        return 1 + inner.nodeCount
                    case let .boundArray(element: element, maxLength: _):
                        return 1 + element.nodeCount
                    case let .boundRange(inner):
                        return 1 + inner.nodeCount
                    case let .reifiedBind(inner):
                        return 1 + inner.nodeCount
                    case let .recursive(base: base, maxDepth: _):
                        return 1 + base.nodeCount
                    case let .scaledArray(inner, lengthRange: _, scaling: _):
                        return 1 + inner.nodeCount
                    case let .unique(inner):
                        return 1 + inner.nodeCount
                    case let .classified(inner):
                        return 1 + inner.nodeCount
                    case let .metamorphed(inner, _):
                        return 1 + inner.nodeCount
                    // Unfold expands to one interpreter recursion level per drawn depth, so the stack budget must count the worst case, not a single node.
                    case let .unfolded(depthRange: depthRange):
                        return 1 + depthRange.upperBound
                    case .getSized:
                        return 1
                    case let .isomorphed(inner, _):
                        return 1 + inner.nodeCount
                }
        }
    }

    package var outputType: RecipeType {
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
                    case let .pruned(inner):
                        return inner.outputType
                    case let .array(inner, lengthRange: _):
                        return RecipeType.arrayOf(inner.outputType)
                    case let .oneOf(recipes):
                        return recipes[0].outputType
                    case let .weightedOneOf(branches):
                        return branches[0].recipe.outputType
                    case let .filtered(inner, _):
                        return inner.outputType
                    case let .resized(inner, size: _):
                        return inner.outputType
                    case let .zipped(a, _):
                        // The build keeps the raw `.zip` output as `[element, element]`, so the recipe produces an array of the child type, not a scalar.
                        return .arrayOf(a.outputType)
                    case let .optional(inner):
                        return inner.outputType
                    case let .boundArray(element: element, maxLength: _):
                        return .arrayOf(element.outputType)
                    case .boundRange:
                        return .int
                    case let .reifiedBind(inner):
                        return inner.outputType
                    case let .recursive(base: base, maxDepth: _):
                        return base.outputType
                    case let .scaledArray(inner, lengthRange: _, scaling: _):
                        return .arrayOf(inner.outputType)
                    case let .unique(inner):
                        return inner.outputType
                    case let .classified(inner):
                        return inner.outputType
                    case let .metamorphed(inner, _):
                        // Metamorph produces [original, transformed copies...] as an array of the inner type.
                        return .arrayOf(inner.outputType)
                    case .unfolded:
                        return .int
                    case .getSized:
                        return .int
                    case let .isomorphed(inner, transform):
                        return transform.applicableType ?? inner.outputType
                }
        }
    }
}
