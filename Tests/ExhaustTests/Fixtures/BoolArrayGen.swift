@testable import Exhaust

func boolArrayGen() -> ReflectiveGenerator<Void, [Bool]> {
    Gen.arrayOf(Gen.pick(choices: [
        (1, .pure(true)),
        (1, .pure(false)),
    ]), Gen.choose(in: 1...10))
}
