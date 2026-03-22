//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

public extension Gen {
    static func zip<each T>(
        _ generators: repeat ReflectiveGenerator<each T>,
        isOpaque: Bool = false
    ) -> ReflectiveGenerator<(repeat each T)> {
        var erased: ContiguousArray<ReflectiveGenerator<Any>> = []
        erased.reserveCapacity(5) // It will rarely exceed this size
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip(erased, isOpaque: isOpaque),
            continuation: { .pure($0 as! [Any]) }
        )

        return Gen.contramap(
            { (tuple: (repeat each T)) -> [Any] in
                var values: [Any] = []
                for value in repeat each tuple {
                    values.append(value)
                }
                return values
            },
            impure._map { (values: [Any]) -> (repeat each T) in
                var index = 0
                func next<U>(_: U.Type) -> U {
                    defer { index += 1 }
                    return values[index] as! U
                }
                return (repeat next((each T).self))
            }
        )
    }
}
