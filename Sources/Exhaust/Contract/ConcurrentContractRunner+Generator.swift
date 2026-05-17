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

    // The marker tag controls whether lane assignments appear as parameters in the covering array. At concurrencyLevel <= 3, the per-position domain grows by a factor of (lanes + 1):
    //   2 lanes: x3 (prefix/A/B)   → 3 commands x 3 markers =  9, ~81 rows at t=2
    //   3 lanes: x4 (prefix/A/B/C) → 3 commands x 4 markers = 12, ~144 rows at t=2
    // This keeps the combinatorial growth bounded while including lane assignments in the covering array alongside command types and their arguments.
    //
    // At concurrencyLevel 4+, the multiplier grows to x5...x9 and rows scale quadratically with domain size: 3 commands x 5 markers = 15 → ~225 rows; x9 = 27 → ~729 rows. The .laneControl tag excludes the marker from coverage, keeping row count at commandTypes² and leaving lane exploration to random sampling.
    let markerGen: Generator<ScheduleMarker> = switch concurrencyLevel {
    case 1:
        Gen.just(ScheduleMarker.prefix)
    case 2 ... 3:
        Gen.choose(in: UInt8(0) ... UInt8(concurrencyLevel))
            .map { ScheduleMarker(rawValue: $0) }
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
