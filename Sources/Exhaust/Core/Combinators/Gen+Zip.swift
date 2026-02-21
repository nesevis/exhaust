//
//  Gen+Zip.swift
//  Exhaust
//
//  Created by Chris Kolbu on 21/7/2025.
//

public extension Gen {
    @inlinable
    static func zip<each T>(
        _ generators: repeat ReflectiveGenerator<each T>,
    ) -> ReflectiveGenerator<(repeat each T)> {
        // TODO: These extensions are good candidates for InlineArrays with declared sizes
        var erased: ContiguousArray<ReflectiveGenerator<Any>> = []
        for generator in repeat each generators {
            erased.append(generator.erase())
        }

        let impure: ReflectiveGenerator<[Any]> = .impure(
            operation: .zip(erased),
            continuation: { .pure($0 as! [Any]) },
        )

        return impure.mapped(
            forward: { values in
                var index = 0
                func next<U>(_: U.Type) -> U {
                    defer { index += 1 }
                    return values[index] as! U
                }
                return (repeat next((each T).self))
            },
            backward: { tuple in
                var values: [Any] = []
                for value in repeat each tuple {
                    values.append(value)
                }
                return values
            },
        )
    }
}
