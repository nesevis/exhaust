// MARK: - Static Data-Dependence Detection

//
// Screening analysis records only the pick arm it selected, so the arms it skipped leave no trace in the
// template. The question those arms still have to answer is whether the generator's *shape* depends on a
// drawn value, because a shape that varies is a domain the enumerable parameter model does not cover.
//
// The answer is available from the generator graph without running it. Public `bind` and `flatMap` reify as
// `.transform(kind: .bind, ...)`, so the walk looks for that node rather than trying to see through a
// continuation. The walk is self-terminating in the direction that matters: the first bind ends it.

package extension FreerMonad where Operation == ReflectiveOperation {
    /// Whether this generator's shape depends on a value drawn while generating it.
    ///
    /// Reports `true` for a reified bind, and for a graph deeper than ``dataDependenceDepthLimit``. Over-reporting costs a sampling phase that was not strictly needed; under-reporting would let screening claim a domain it never enumerated, so every uncertain case resolves to `true`. The operation switch is deliberately exhaustive: a new operation kind has to state its own answer rather than inherit a default that reads as safe.
    ///
    /// - Note: Reads the reified node, so a combinator that sequences through ``FreerMonad/bind(_:)`` without emitting one is invisible here. ``Gen/shuffled(_:)`` and ``Gen/slice(of:)`` are built that way. Their shape dependence has never been visible to this question — a materialized tree does not record it either — so this walk matches what a fully materialized arm would have reported, and no more.
    /// - Complexity: O(*n*) in the number of graph nodes visited, which stops at the first bind.
    var hasDataDependentShape: Bool {
        Self.hasDataDependentShape(erase(), depth: 0)
    }

    /// Bounds the walk so a pathologically nested generator cannot exhaust the stack. A graph this deep is treated as data-dependent rather than analyzed further.
    private static var dataDependenceDepthLimit: Int {
        64
    }

    private static func hasDataDependentShape(_ generator: AnyGenerator, depth: Int) -> Bool {
        guard depth < dataDependenceDepthLimit else {
            return true
        }
        guard case let .impure(operation, _) = generator else {
            return false
        }
        return hasDataDependentShape(operation, depth: depth)
    }

    private static func hasDataDependentShape(_ operation: ReflectiveOperation, depth: Int) -> Bool {
        let next = depth + 1
        switch operation {
            case let .transform(kind, inner):
                // `.lazy` builds a bind, so a recursive derived arm answers here without reaching its deferred closure.
                if case .bind = kind {
                    return true
                }
                return hasDataDependentShape(inner, depth: next)

            case .chooseBits, .just, .getSize:
                return false

            case let .pick(choices, _):
                return choices.contains { hasDataDependentShape($0.generator, depth: next) }

            case let .zip(generators, _):
                return generators.contains { hasDataDependentShape($0, depth: next) }

            case let .sequence(length, gen, _):
                return hasDataDependentShape(length.erase(), depth: next)
                    || hasDataDependentShape(gen, depth: next)

            case let .contramap(_, next: inner):
                return hasDataDependentShape(inner, depth: next)

            case let .prune(inner):
                return hasDataDependentShape(inner, depth: next)

            case let .resize(_, inner):
                return hasDataDependentShape(inner, depth: next)

            case let .filter(gen, _, _, _, _):
                return hasDataDependentShape(gen, depth: next)

            case let .classify(gen, _, _):
                return hasDataDependentShape(gen, depth: next)

            case let .unique(gen, _, _):
                return hasDataDependentShape(gen, depth: next)
        }
    }
}
