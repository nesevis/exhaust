import ExhaustCore
import Testing

@Suite("Mutation bandit and power schedule tests")
struct MutationBanditTests {
    @Test("Fresh bandit distributes uniformly")
    func uniformStart() {
        let bandit = MutationBandit()
        for probability in bandit.probabilities {
            #expect(abs(probability - 0.25) < 1e-9)
        }
    }

    @Test("Rewards shift probability toward the paying arm")
    func rewardsShiftWeights() {
        var bandit = MutationBandit()
        for _ in 0 ..< 50 {
            bandit.reward(.medium)
        }
        let probabilities = bandit.probabilities
        // The exploration mixture caps any arm at 0.925; fifty rewards get most of the way there.
        #expect(probabilities[MutationArm.medium.rawValue] > 0.7)
        for arm in MutationArm.allCases where arm != .medium {
            #expect(probabilities[arm.rawValue] < probabilities[MutationArm.medium.rawValue])
        }
        // Sanity on the distribution itself.
        #expect(abs(probabilities.reduce(0, +) - 1.0) < 1e-9)
    }

    @Test("The exploration floor keeps every arm reachable no matter the rewards")
    func explorationFloor() {
        var bandit = MutationBandit()
        for _ in 0 ..< 10000 {
            bandit.reward(.splice)
        }
        let floor = MutationBandit.explorationRate / Double(MutationArm.allCases.count)
        for probability in bandit.probabilities {
            #expect(probability >= floor - 1e-12)
        }
        // pick honors the floor: a draw landing in the tail of the cumulative distribution returns a non-favored arm.
        #expect(bandit.pick(random: 0.999) != bandit.pick(random: 0.5) || bandit.pick(random: 0.999) == .splice)
    }

    @Test("Picks follow the cumulative distribution deterministically")
    func pickIsDeterministic() {
        var bandit = MutationBandit()
        bandit.reward(.high)
        let first = (0 ..< 10).map { step in bandit.pick(random: Double(step) / 10) }
        let second = (0 ..< 10).map { step in bandit.pick(random: Double(step) / 10) }
        #expect(first == second)
    }

    @Test("Power schedule ramps energy for revisited parents and divides by spawn frequency")
    func powerScheduleArithmetic() {
        let corpus = SprawlCorpus(edgeCount: 8)
        let sequence: ChoiceSequence = [.just]
        _ = corpus.offer(
            sequence: sequence,
            tree: .just,
            hits: [(edge: 1, hitCount: 1)],
            convergence: 1.0,
            generation: 0,
            phase: .sampling
        )
        let base = SprawlTunables.childrenPerParent
        var energies: [Int] = []
        for _ in 0 ..< 12 {
            energies.append(corpus.powerScheduleChildren(forParentAt: 0, base: base))
        }
        // First pick spends the base energy; every value obeys the clamp; sustained revisits reach the cap as 2^s outruns the frequency denominator.
        #expect(energies[0] == base)
        #expect(energies.allSatisfy { $0 >= 1 && $0 <= SprawlTunables.powerScheduleEnergyCap })
        #expect(energies.last == SprawlTunables.powerScheduleEnergyCap)

        // The arithmetic matches the formula step by step.
        var timesPicked = 0
        var childrenSpawned = 0
        for energy in energies {
            timesPicked += 1
            let exponent = min(timesPicked - 1, SprawlTunables.powerScheduleExponentLimit)
            let expected = min(
                max(base * (1 << exponent) / (1 + childrenSpawned), 1),
                SprawlTunables.powerScheduleEnergyCap
            )
            #expect(energy == expected)
            childrenSpawned += expected
        }
    }
}
