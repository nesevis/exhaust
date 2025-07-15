@testable import Exhaust

func boolArrayGen() -> ReflectiveGen<Void, [Bool]> {
    return Gen.getSize().bind { size in
        guard size > 0 else {
            // Base case: If size is 0, return an empty array.
            return .pure([])
        }
        
        let boolGen = Gen.pick(choices: [
            (1, "true", .pure(true)),
            (1, "false", .pure(false))
        ])
        
        let restOfArrayGen = Gen.resize(to: size - 1, boolArrayGen())
        
        // 3. Combine the bool and the rest of the array.
        return boolGen.bind { head in
            restOfArrayGen.map { tail in
                [head] + tail
            }
        }
    }
}
