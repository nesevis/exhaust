import ExhaustCore
import Testing

/// Validates that a generator round-trips through reflect and replay: generate a value,
/// reflect it into a choice tree, replay from that tree, and assert the replayed value
/// matches the original.
@discardableResult
package func validateGenerator<Output: Equatable>(_ gen: Generator<Output>) throws -> (recipe: ChoiceTree, instance: Output) {
    let (instance, _) = try generate(gen)
    let recipe = try #require(try Interpreters.reflect(gen, with: instance))
    let replay = try #require(try Interpreters.replay(gen, using: recipe))
    #expect(instance == replay)
    return (recipe, instance)
}
