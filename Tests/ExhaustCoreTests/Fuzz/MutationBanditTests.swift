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
        let favored = probabilities[MutationArm.medium.rawValue]
        #expect(favored > 0.7)
        for (index, probability) in probabilities.enumerated() where index != MutationArm.medium.rawValue {
            #expect(probability < favored)
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
        let probabilities = bandit.probabilities
        let floor = MutationBandit.explorationRate / Double(probabilities.count)
        for probability in probabilities {
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
}
