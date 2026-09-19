import ExhaustCore
import Testing

/// Reflects a value into a choice tree and replays it, requiring the replayed value to equal the original.
///
/// This is the single-target half of what `#examine` checks over a sample: it reaches values sampling cannot, such as one outside a state-space preset or deeper than the annotation default.
package func expectReflectionRoundTrip<Value: Equatable>(_ generator: Generator<Value>, value: Value) throws {
    let tree = try #require(try Interpreters.reflect(generator, with: value))
    #expect(try Interpreters.replay(generator, using: tree) == value)
}

/// Runs an operation that must throw ``ReflectionError/inputWasOutOfGeneratorRange``, recording an issue when it succeeds or throws anything else.
package func expectReflectionOutOfRange(_ operation: () throws -> Void) {
    do {
        try operation()
        Issue.record("Expected reflection to reject the value as out of range")
    } catch let error as ReflectionError {
        guard case .inputWasOutOfGeneratorRange = error else {
            Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected inputWasOutOfGeneratorRange, got \(error)")
    }
}
