// Schedule marker generator construction for concurrent contract testing.
import ExhaustCore

extension Gen {
    /// Produces a lane-control chooseBits tagged with ``TypeTag.laneControl``, excluding it from the covering array's parameter set at high concurrency levels.
    static func chooseLaneControl(in range: ClosedRange<UInt8>) -> Generator<UInt8> {
        let operation = ReflectiveOperation.chooseBits(
            min: UInt64(range.lowerBound),
            max: UInt64(range.upperBound),
            tag: .laneControl,
            isRangeExplicit: true
        )
        return .impure(operation: operation) { result in
            guard let convertible = result as? any BitPatternConvertible else {
                fatalError("chooseLaneControl: unexpected result type")
            }
            return .pure(UInt8(convertible.bitPattern64))
        }
    }
}

/// Zips a schedule marker generator onto each branch of the command pick.
///
/// Takes the spec's command generator (a `pick` over weighted command branches) and prepends a `chooseBits(0...N)` schedule marker to each branch via `zip`, where N is the concurrency level. The resulting generator produces `(ScheduleMarker, Command)` tuples where the marker controls lane assignment and the command is the original spec command with all its argument generators intact. The array order of non-prefix markers defines the interleaving schedule. The reducer shrinks counterexamples by deleting elements (shorter sequence) and minimizing markers toward 0 (moving commands from concurrent lanes into the sequential prefix).
///
/// The structure after transformation:
/// ```
/// pick([
///     (w, zip(marker, genCommandA)),
///     (w, zip(marker, genCommandB)),
///     ...
/// ])
/// ```
///
/// This gives each array element a pick-at-top structure that the choice-graph reducer handles naturally: structural deletion removes entire elements (shorter counterexample), and value minimization on the marker's chooseBits drives it toward 0/prefix (less concurrency).
func zipScheduleMarker<Command>(
    onto commandGen: Generator<Command>,
    concurrencyLevel: Int
) -> Generator<(ScheduleMarker, Command)> {
    guard let choices = extractPickChoices(from: commandGen) else {
        fatalError("Command generator is in unexpected format")
    }

    // Lane markers are always tagged .laneControl so the lane-collapse encoder can target them during reduction. Random sampling with .constant scaling provides sufficient lane diversity without including markers in the covering array.
    let markerGen: Generator<ScheduleMarker> = switch concurrencyLevel {
    case 1:
        Gen.just(ScheduleMarker.prefix)
    default:
        Gen.chooseLaneControl(in: 0 ... UInt8(concurrencyLevel))
            .map { ScheduleMarker(rawValue: $0) }
    }
    let taggedChoices = choices.map { choice in
        let branchGen: Generator<Command> = choice.generator.map { $0 as! Command }
        let zipped = Gen.zip(markerGen, branchGen)
        return (weight: choice.weight, generator: zipped)
    }

    return Gen.pick(choices: taggedChoices)
}
