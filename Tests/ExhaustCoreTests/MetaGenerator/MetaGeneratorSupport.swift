import ExhaustCore
import ExhaustTestSupport
import Testing

// Shared helpers and fixtures for the MetaGenerator invariant matrix.

/// Accumulates how often a swept invariant reached a real verdict versus skipped one.
///
/// A cell in the matrix can pass three ways: the check ran and held (`evaluated`), the operation could not reflect so the check returned nil (`vacuous`), or reflection threw and the helper swallowed it (`thrown`). The test report shows only pass or fail, so without this a whole (kind, invariant) cell can be green because it never actually ran. Each swept invariant asserts `evaluated > 0` against its tally so wholesale vacuity fails loudly.
final class Tally {
    var evaluated = 0
    var vacuous = 0
    var thrown = 0

    var summary: String {
        "evaluated=\(evaluated), vacuous=\(vacuous), thrown=\(thrown)"
    }
}

/// Checks a property against all generated values, recording verdicts into `tally`. Returns true if the property held for every value that produced a verdict.
///
/// The `check` returns `nil` to signal a vacuous skip (for example, a forward-only generator that cannot reflect), `true` for a held verdict, and `false` for a violation. A throw from generation or from `check` is counted as `thrown`, not propagated, so a recoverable reflection failure is recorded rather than silently treated as a pass.
func checkAllValues(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    tally: Tally,
    check: (Any) throws -> Bool?
) -> Bool {
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: maxRuns)
    while true {
        let element: (value: Any, tree: ChoiceTree)?
        do {
            element = try iter.next()
        } catch {
            tally.thrown += 1
            return true
        }
        guard let (value, _) = element else {
            return true
        }
        do {
            switch try check(value) {
                case .none:
                    tally.vacuous += 1
                case .some(true):
                    tally.evaluated += 1
                case .some(false):
                    tally.evaluated += 1
                    return false
            }
        } catch {
            tally.thrown += 1
        }
    }
}

/// Checks a property against all generated choice trees, recording verdicts into `tally`. Returns true if the property held for every tree that produced a verdict. See ``checkAllValues`` for the `nil`/`true`/`false` contract.
func checkAllTrees(
    _ gen: AnyGenerator,
    maxRuns: UInt64 = 10,
    tally: Tally,
    check: (ChoiceTree) throws -> Bool?
) -> Bool {
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: maxRuns)
    while true {
        let element: (value: Any, tree: ChoiceTree)?
        do {
            element = try iter.next()
        } catch {
            tally.thrown += 1
            return true
        }
        guard let (_, tree) = element else {
            return true
        }
        do {
            switch try check(tree) {
                case .none:
                    tally.vacuous += 1
                case .some(true):
                    tally.evaluated += 1
                case .some(false):
                    tally.evaluated += 1
                    return false
            }
        } catch {
            tally.thrown += 1
        }
    }
}

/// Returns whether the recipe contains a combinator of the given kind at any depth, matched by `predicate`.
func recipeContains(_ recipe: GenRecipe, where predicate: (GenRecipe.CombinatorKind) -> Bool) -> Bool {
    guard case let .combinator(kind) = recipe else {
        return false
    }
    if predicate(kind) {
        return true
    }
    switch kind {
        case let .mapped(inner, _),
             let .array(inner, _),
             let .filtered(inner, _),
             let .resized(inner, _),
             let .optional(inner),
             let .boundRange(inner),
             let .scaledArray(inner, _, _),
             let .classified(inner),
             let .metamorphed(inner, _),
             let .isomorphed(inner, _),
             let .unique(inner):
            return recipeContains(inner, where: predicate)
        case let .boundArray(element, _):
            return recipeContains(element, where: predicate)
        case let .recursive(base, _):
            return recipeContains(base, where: predicate)
        case let .oneOf(recipes):
            return recipes.contains { recipeContains($0, where: predicate) }
        case let .weightedOneOf(branches):
            return branches.contains { recipeContains($0.recipe, where: predicate) }
        case let .zipped(first, second):
            return recipeContains(first, where: predicate) || recipeContains(second, where: predicate)
        case .unfolded, .getSized:
            return false
    }
}

/// Mean length of the arrays a generator produces at a fixed size override, over `samples` runs.
func meanArrayLength(_ gen: AnyGenerator, size: UInt64, samples: UInt64) throws -> Double {
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: 42, maxRuns: samples, sizeOverride: size)
    var total = 0
    var count = 0
    while let (value, _) = try iter.next() {
        guard let array = value as? [Any] else {
            continue
        }
        total += array.count
        count += 1
    }
    return count > 0 ? Double(total) / Double(count) : 0
}

/// Counts how many of a recipe's generated values reflect to a non-nil tree. A throw or a nil reflection both count as "did not reflect", since `try?` collapses them.
func reflectableValueCount(_ recipe: GenRecipe, seed: UInt64, maxRuns: UInt64) throws -> Int {
    let gen = buildGenerator(from: recipe)
    var iter = ValueAndChoiceTreeInterpreter(gen, seed: seed, maxRuns: maxRuns)
    var reflected = 0
    while let (value, _) = try iter.next() {
        if (try? Interpreters.reflect(gen, with: value)) != nil {
            reflected += 1
        }
    }
    return reflected
}

/// Returns whether the value is nil at any level of optional nesting.
func containsNil(_ value: Any) -> Bool {
    let mirror = Mirror(reflecting: value)
    guard mirror.displayStyle == .optional else {
        return false
    }
    guard let child = mirror.children.first else {
        return true
    }
    return containsNil(child.value)
}

// MARK: - Matrix Configuration

/// Output types the universal invariants sweep over. Every operation the recipe language can produce for these types gets each invariant automatically.
let metaRecipeTypes: [RecipeType] = [.int, .bool, .double, .string, .character, .arrayOf(.int)]

/// A named recipe exercising a single combinator, for the per-combinator reflection-coverage sweep.
struct CombinatorFixture: Sendable, CustomStringConvertible {
    let name: String
    let recipe: GenRecipe

    var description: String {
        name
    }
}

/// One fixture per combinator whose output is reflectable, so the coverage sweep can assert each reflects rather than skipping it. `boundRange` and `unfolded` are omitted deliberately: both build on a backward-less `.bind`/unfold, so their outputs are not reflectable by construction and a nil reflection is expected rather than a regression.
let reflectableCombinatorFixtures: [CombinatorFixture] = [
    .init(name: "mapped", recipe: .combinator(.mapped(.leaf(.int(0 ... 10)), .increment))),
    .init(name: "array", recipe: .combinator(.array(.leaf(.int(0 ... 5)), lengthRange: 1 ... 3))),
    .init(name: "oneOf", recipe: .combinator(.oneOf([.leaf(.int(0 ... 5)), .leaf(.int(6 ... 10))]))),
    .init(name: "weightedOneOf", recipe: .combinator(.weightedOneOf([
        .init(weight: 1, recipe: .leaf(.int(0 ... 5))),
        .init(weight: 2, recipe: .leaf(.int(6 ... 10))),
    ]))),
    .init(name: "filtered", recipe: .combinator(.filtered(.leaf(.int(-20 ... 20)), .isEven))),
    .init(name: "resized", recipe: .combinator(.resized(.leaf(.int(0 ... 100)), size: 10))),
    .init(name: "optional", recipe: .combinator(.optional(.leaf(.int(-10 ... 10))))),
    .init(name: "recursive", recipe: .combinator(.recursive(base: .leaf(.int(0 ... 5)), maxDepth: 2))),
    .init(name: "scaledArray", recipe: .combinator(.scaledArray(.leaf(.int(0 ... 5)), lengthRange: 0 ... 3, scaling: .linear))),
    .init(name: "metamorphed", recipe: .combinator(.metamorphed(.leaf(.int(0 ... 5)), .increment))),
    .init(name: "zipped", recipe: .combinator(.zipped(.leaf(.int(-10 ... 10)), .leaf(.int(0 ... 100))))),
    .init(name: "unique", recipe: .combinator(.unique(.leaf(.int(0 ... 1000))))),
    .init(name: "classified", recipe: .combinator(.classified(.leaf(.int(0 ... 10))))),
    .init(name: "boundArray", recipe: .combinator(.boundArray(element: .leaf(.int(0 ... 5)), maxLength: 3))),
    .init(name: "getSized", recipe: .combinator(.getSized)),
    .init(name: "isomorphed", recipe: .combinator(.isomorphed(.leaf(.int(0 ... 10)), .increment))),
]

/// Node-count ceiling for recipes fed to the invariants. Debug builds give each interpreter recursion level a fat stack frame, so total recipe size, not nesting depth alone, is what overflows the 512 KiB test-thread stack. Calibrated empirically with the ExhaustStackProbe executable (2026-07-07, arm64 debug, interpreter case handlers outlined): nested filter chains are the worst shape because every level stacks a CGS tuning pass, crashing between 80 and 96 nodes; mapped, optional, unique, and classified chains all clear 112. The constant is the worst ceiling with a ~2x margin for platform and toolchain variance. Recalibrate with the probe after changing any interpreter's recursion frames or adding a recipe kind with a new nesting shape.
let metaRecipeNodeBudget = 40
