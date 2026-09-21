// MARK: - Static Choice Detection

//
// The pick model gives screening one parameter per pick, the branch index, and leaves every choice inside an arm to the materializer's PRNG. That is sound for a covering run, which random sampling follows, and unsound for an exhaustive verdict, which claims the rows were the whole domain. An arm is only covered by its branch index when it draws nothing.
//
// The answer is read from the generator graph because screening analysis records one arm and elides the rest, so the template cannot answer for arms it never produced.

package extension FreerMonad where Operation == ReflectiveOperation {
    /// Whether generating from this generator can draw any choice, read the size, or build a generator from a drawn value.
    ///
    /// Reports `true` for every case it cannot prove constant, and for a graph deeper than ``choiceDetectionDepthLimit``. Over-reporting costs a sampling phase that was not strictly needed; under-reporting lets screening claim a domain it never enumerated. The operation switch is deliberately exhaustive so that a new operation kind has to state its own answer.
    ///
    /// - Note: Reads reified nodes only and cannot see through a continuation, so `false` means "no draw in the graph", not "constant". Screening analysis treats it as a cost gate: an arm that answers `false` is cheap to materialize, and the recorded subtree gives the final answer. A `getSize` counts because exhaustive rows run at one size while sampling sweeps sizes 1 through 100.
    /// - Complexity: O(*n*) in the number of graph nodes visited, which stops at the first choice.
    var drawsChoice: Bool {
        Self.drawsChoice(erase(), depth: 0)
    }

    private static var choiceDetectionDepthLimit: Int {
        64
    }

    private static func drawsChoice(_ generator: AnyGenerator, depth: Int) -> Bool {
        guard depth < choiceDetectionDepthLimit else {
            return true
        }
        guard case let .impure(operation, _) = generator else {
            return false
        }
        return drawsChoice(operation, depth: depth)
    }

    private static func drawsChoice(_ operation: ReflectiveOperation, depth: Int) -> Bool {
        let next = depth + 1
        switch operation {
            case let .chooseBits(min, max, _, _, _, _):
                return min != max

            case .just:
                return false

            case .getSize, .sequence:
                return true

            case let .pick(choices, _):
                return choices.count > 1 || choices.contains { drawsChoice($0.generator, depth: next) }

            case let .zip(generators, _):
                return generators.contains { drawsChoice($0, depth: next) }

            case let .transform(kind, inner):
                // The generator a bind builds is not in the graph, so what it draws cannot be read from here.
                if case .bind = kind {
                    return true
                }
                return drawsChoice(inner, depth: next)

            case let .contramap(_, next: inner):
                return drawsChoice(inner, depth: next)

            case let .prune(inner):
                return drawsChoice(inner, depth: next)

            case let .resize(_, inner):
                return drawsChoice(inner, depth: next)

            case let .filter(gen, _, _, _, _):
                return drawsChoice(gen, depth: next)

            case let .classify(gen, _, _):
                return drawsChoice(gen, depth: next)

            case let .unique(gen, _, _):
                return drawsChoice(gen, depth: next)
        }
    }
}
