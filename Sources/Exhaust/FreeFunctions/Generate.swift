//
//  Generate.swift
//  Exhaust
//
//  Created by Chris Kolbu on 22/2/2026.
//

@_spi(ExhaustInternal) import ExhaustCore

extension PropertyTest {
    /// This is it. This parameter pack + closure will let us enforce applicative generator construction by sheer force of user laziness.
    static func generate<each T, R>(
        _ generators: repeat ReflectiveGenerator<each T>,
        closure: @escaping ((repeat each T)) -> R,
    ) -> ReflectiveGenerator<R> {
        Gen.zip(repeat each generators).map(closure)
    }
}
