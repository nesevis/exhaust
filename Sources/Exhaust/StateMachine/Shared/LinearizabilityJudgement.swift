// The interleaving search all three concurrent runners share.
//
// A task-based run reaches it when the equivalence rejects the reference replay; a thread-based run reaches it when the oracle comparison flags a probe. From that point the question is identical — does any valid ordering of the recorded lane commands explain what the lanes observed? — so the replay closures are built here, once, and the callers differ only in what wraps the call (the cooperative drain bridge, the preemptive stall timeout) and how they consume the verdict.
import ExhaustCore

// MARK: - Spec Replay

/// The operations the interleaving search performs on a spec, expressed asynchronously so one search serves both spec protocols.
///
/// A synchronous spec gives up nothing by presenting them as `async`. The search already runs behind a bridge in every mode — the cooperative drain for a task-based run, `blockingAwait` for a thread-based one — and an `async` function that never suspends adds no hop of its own. Without this the synchronous preemptive backend carried a second copy of the whole search's closure set, differing from the asynchronous one only in where the `await` keywords fell, which is the kind of twin that drifts.
///
/// Construct one at the point of use. Neither constructor captures anything, so a caller inside a `@Sendable` closure builds its own rather than carrying one across the boundary.
struct SpecReplay<Spec: StateMachineSpecBase> {
    /// Builds a fresh instance with the same setup applied, reporting a setup error rather than throwing so the search can reject that ordering instead of crashing into an unconfigured system under test.
    let makeSpec: (Spec.SetupStep?) async -> (spec: Spec, setupError: (any Error)?)
    let run: (Spec, Spec.Command) async throws -> CommandResponse
    let checkInvariants: (Spec) async throws -> Void
    let isEquivalent: (Spec, Spec.SystemUnderTest) async -> Bool
}

extension SpecReplay where Spec: StateMachineSpec {
    /// The replay for a spec whose every member is synchronous.
    static var synchronous: Self {
        Self(
            makeSpec: { Spec.makeSpec(setupStep: $0) },
            run: { try $0.run($1) },
            checkInvariants: { try $0.checkInvariants() },
            isEquivalent: { $0.equivalenceCheck($1) }
        )
    }
}

extension SpecReplay where Spec: AsyncStateMachineSpec {
    /// The replay for a spec with any asynchronous member.
    static var asynchronous: Self {
        Self(
            makeSpec: { await Spec.makeSpec(setupStep: $0) },
            run: { try await $0.run($1) },
            checkInvariants: { try await $0.checkInvariants() },
            isEquivalent: { await $0.equivalenceCheck($1) }
        )
    }
}

// MARK: - Search

/// Asks whether any valid ordering of the recorded lane commands reproduces what the lanes observed and satisfies the equivalence.
///
/// Builds the replay closures every search needs the same way: a fresh spec per sibling retry (the same setup every time, a setup error failing that ordering rather than crashing into an unconfigured system under test), the prefix replayed with skips tolerated, each concurrent command replayed with invariants checked after it, and the equivalence as the final-state oracle. An invariant that fails after a replayed command rejects that candidate ordering — the ordering is not one the run could have taken — and is not charged against the replay budget, which bounds replays and not judgements. A sequence whose invariants fail under every ordering has already been reported by the reference replay, which runs before the search in every mode.
func searchForExplainingOrder<Spec: StateMachineSpecBase>(
    concurrentSpec: Spec,
    setupStep: Spec.SetupStep?,
    prefixCommands: [Spec.Command],
    laneResponses: [[ObservedResponse<Spec.Command>]],
    replay: SpecReplay<Spec>
) async -> LinearizabilityResult {
    let checker = LinearizabilityChecker(laneResponses: laneResponses)
    var replaySpec: Spec?
    let result = await checker.check(
        prefixLength: prefixCommands.count,
        replayPrefix: {
            let (fresh, setupError) = await replay.makeSpec(setupStep)
            guard setupError == nil else {
                return false
            }
            for command in prefixCommands {
                do {
                    // The prefix only re-establishes state; its responses are judged in `replayCommand`, not here.
                    _ = try await replay.run(fresh, command)
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
                let response = try await replay.run(spec, laneResponses[laneIndex][commandIndex].command)
                try await replay.checkInvariants(spec)
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
            return await replay.isEquivalent(concurrentSpec, spec.systemUnderTest)
        },
        failureDescription: {
            concurrentSpec.failureDescription()
        }
    )
    return makeLinearizabilityResult(result, laneObservations: laneResponses)
}
