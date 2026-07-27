// The interleaving search both concurrent modes share.
//
// A task-based run reaches it when the equivalence rejects the reference replay; a thread-based run reaches it when the oracle comparison flags a probe. From that point the question is identical — does any valid ordering of the recorded lane commands explain what the lanes observed? — so the replay closures are built here, once, and the callers differ only in what wraps the call (the cooperative drain bridge, the preemptive stall timeout) and how they consume the verdict.
import ExhaustCore

/// Asks whether any valid ordering of the recorded lane commands reproduces what the lanes observed and satisfies the equivalence.
///
/// Builds the replay closures every search needs the same way: a fresh spec per sibling retry via `makeSpec` (the same setup every time, a setup error failing that ordering rather than crashing into an unconfigured system under test), the prefix replayed with skips tolerated, each concurrent command replayed with invariants checked after it, and the equivalence as the final-state oracle. An invariant that fails after a replayed command rejects that candidate ordering — the ordering is not one the run could have taken — and is not charged against the replay budget, which bounds replays and not judgements. A sequence whose invariants fail under every ordering has already been reported by the reference replay, which runs before the search in both modes.
func searchForExplainingOrder<Spec: AsyncStateMachineSpec>(
    concurrentSpec: Spec,
    setupStep: Spec.SetupStep?,
    prefixCommands: [Spec.Command],
    laneResponses: [[ObservedResponse<Spec.Command>]]
) async -> LinearizabilityResult {
    let checker = LinearizabilityChecker(laneResponses: laneResponses)
    var replaySpec: Spec?
    let result = await checker.check(
        prefixLength: prefixCommands.count,
        replayPrefix: {
            let (fresh, setupError) = await Spec.makeSpec(setupStep: setupStep)
            guard setupError == nil else {
                return false
            }
            for command in prefixCommands {
                do {
                    try await fresh.run(command)
                } catch is StateMachineSkip {
                    continue
                } catch {
                    return false
                }
            }
            replaySpec = fresh
            return true
        },
        replayCommand: { laneIndex, commandIndex in
            guard let spec = replaySpec else {
                return nil
            }
            do {
                let response = try await spec.run(laneResponses[laneIndex][commandIndex].command)
                try await spec.checkInvariants()
                return .init(returnValue: response.returnValue, isSkipped: false)
            } catch is StateMachineSkip {
                return .init(returnValue: nil, isSkipped: true)
            } catch {
                return nil
            }
        },
        checkOracle: {
            guard let spec = replaySpec else {
                return false
            }
            return await concurrentSpec.equivalenceCheck(spec.systemUnderTest)
        },
        failureDescription: {
            concurrentSpec.failureDescription()
        }
    )
    return makeLinearizabilityResult(result, laneObservations: laneResponses)
}
