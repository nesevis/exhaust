import ExhaustCore
import Testing

/// Compares both generated values and the next random draw so forwarding cannot silently change random consumption.
///
/// The trailing `UInt64` draw is what makes a difference in random consumption observable: two generators can agree on every value they produce and still leave the stream in different states. Pass a small `size` to make an ignored scaling argument observable, or `nil` to run at the interpreter's default size.
///
/// - Parameters:
///   - generator: The generator under test.
///   - reference: The generator whose stream the first one must match.
///   - seed: The seed both interpreters start from.
///   - size: The size override both interpreters run at, or `nil` to leave the default in place.
///   - draws: How many values to compare.
package func expectMatchingRandomStream<Value: Equatable>(
    _ generator: Generator<Value>,
    reference: Generator<Value>,
    seed: UInt64,
    size: UInt64?,
    draws: Int
) throws {
    let actualZip = Gen.zip(generator, Gen.choose(in: UInt64.min ... UInt64.max))
    let referenceZip = Gen.zip(reference, Gen.choose(in: UInt64.min ... UInt64.max))
    var actualInterpreter = switch size {
        case let .some(size):
            ValueAndChoiceTreeInterpreter(actualZip, seed: seed, sizeOverride: size)
        case .none:
            ValueAndChoiceTreeInterpreter(actualZip, seed: seed)
    }
    var referenceInterpreter = switch size {
        case let .some(size):
            ValueAndChoiceTreeInterpreter(referenceZip, seed: seed, sizeOverride: size)
        case .none:
            ValueAndChoiceTreeInterpreter(referenceZip, seed: seed)
    }
    for _ in 0 ..< draws {
        let actual = try #require(try actualInterpreter.next())
        let expected = try #require(try referenceInterpreter.next())
        #expect(actual.0.0 == expected.0.0)
        #expect(actual.0.1 == expected.0.1)
    }
}
