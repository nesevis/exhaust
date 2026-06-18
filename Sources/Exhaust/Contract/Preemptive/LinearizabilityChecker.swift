import ExhaustCore

/// Tests whether a concurrent execution's observed responses are consistent with some valid sequential ordering.
///
/// Given the sequential prefix, per-lane observed responses from a concurrent execution, and the concurrent spec instance (for oracle comparison), the checker enumerates valid interleavings that preserve per-lane command order. For each ordering, it replays the commands on a fresh spec, compares per-step responses via `structurallyEqual`, and checks the oracle against the concurrent spec's final state. If any ordering produces matching responses and passes the oracle, the execution is linearizable.
///
/// The checker runs post-lane-collapse, so the concurrent phase is typically two to four commands across two lanes (two to six valid orderings).
struct LinearizabilityChecker<Spec: ContractSpec> {
    let prefix: [Spec.Command]
    let laneResponses: [[ObservedResponse<Spec.Command>]]
    let concurrentSpec: Spec

    func check() -> LinearizabilityResult {
        let laneCount = laneResponses.count
        guard laneCount > 0 else {
            return .linearizable
        }

        var cursors = Array(repeating: 0, count: laneCount)
        let totalCommands = laneResponses.reduce(0) { $0 + $1.count }
        var currentOrdering: [ObservedResponse<Spec.Command>] = []
        currentOrdering.reserveCapacity(totalCommands)

        var closestMatchDepth = -1
        var closestOrdering: [ObservedResponse<Spec.Command>] = []

        let found = searchOrderings(
            cursors: &cursors,
            currentOrdering: &currentOrdering,
            totalCommands: totalCommands,
            closestMatchDepth: &closestMatchDepth,
            closestOrdering: &closestOrdering
        )

        if found {
            return .linearizable
        }
        return .notLinearizable(
            closestOrdering: closestOrdering.map(\.commandDescription),
            divergenceStep: closestMatchDepth + 1
        )
    }

    /// Depth-first search over valid interleavings. At each step, tries advancing each lane's cursor in turn.
    private func searchOrderings(
        cursors: inout [Int],
        currentOrdering: inout [ObservedResponse<Spec.Command>],
        totalCommands: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [ObservedResponse<Spec.Command>]
    ) -> Bool {
        if currentOrdering.count == totalCommands {
            return replayAndVerify(currentOrdering, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
        }

        for laneIndex in 0 ..< laneResponses.count {
            let cursor = cursors[laneIndex]
            guard cursor < laneResponses[laneIndex].count else { continue }

            let response = laneResponses[laneIndex][cursor]
            cursors[laneIndex] += 1
            currentOrdering.append(response)

            let found = searchOrderings(
                cursors: &cursors,
                currentOrdering: &currentOrdering,
                totalCommands: totalCommands,
                closestMatchDepth: &closestMatchDepth,
                closestOrdering: &closestOrdering
            )
            if found { return true }

            currentOrdering.removeLast()
            cursors[laneIndex] -= 1
        }

        return false
    }

    /// Replays the prefix and candidate ordering on a fresh spec, comparing each response against the concurrent observation.
    ///
    /// Returns `true` if all responses match and the oracle accepts the final state.
    private func replayAndVerify(
        _ ordering: [ObservedResponse<Spec.Command>],
        closestMatchDepth: inout Int,
        closestOrdering: inout [ObservedResponse<Spec.Command>]
    ) -> Bool {
        let replaySpec = Spec()

        for command in prefix {
            do {
                try replaySpec.run(command)
            } catch {
                return false
            }
        }

        for (index, observed) in ordering.enumerated() {
            do {
                let replayResponse = try replaySpec.run(observed.command)

                if observed.outcome.isSkipped {
                    updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                    return false
                }

                if responsesMatch(observed: observed, replay: replayResponse) == false {
                    updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                    return false
                }
            } catch is ContractSkip {
                if observed.outcome.isSkipped {
                    continue
                }
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            } catch {
                updateClosest(ordering, matchDepth: index, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
                return false
            }
        }

        let oraclePassed = concurrentSpec.oracleCheck(replaySpec.systemUnderTest)
        if oraclePassed == false {
            updateClosest(ordering, matchDepth: ordering.count, closestMatchDepth: &closestMatchDepth, closestOrdering: &closestOrdering)
        }
        return oraclePassed
    }

    private func responsesMatch(observed: ObservedResponse<Spec.Command>, replay: CommandResponse) -> Bool {
        if observed.commandDescription != replay.commandDescription {
            return false
        }

        switch (observed.outcome.returnValue, replay.returnValue) {
            case (nil, nil):
                return true
            case let (observedValue?, replayValue?):
                return structurallyEqual(observedValue, replayValue)
            default:
                return false
        }
    }

    private func updateClosest(
        _ ordering: [ObservedResponse<Spec.Command>],
        matchDepth: Int,
        closestMatchDepth: inout Int,
        closestOrdering: inout [ObservedResponse<Spec.Command>]
    ) {
        if matchDepth > closestMatchDepth {
            closestMatchDepth = matchDepth
            closestOrdering = ordering
        }
    }
}

// MARK: - Result

enum LinearizabilityResult {
    case linearizable
    case notLinearizable(closestOrdering: [String], divergenceStep: Int)
}
