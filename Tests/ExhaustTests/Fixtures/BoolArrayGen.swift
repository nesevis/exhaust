@testable import Exhaust

func boolArrayGen() -> ReflectiveGen<Void, [Bool]> {
    Gen.choose(in: UInt64(1)...10).bind { length in
        Gen.arrayOf(Gen.pick(choices: [
            (1, "1", .pure(true)),
            (1, "0", .pure(false)),
        ]), length)
    }
}
