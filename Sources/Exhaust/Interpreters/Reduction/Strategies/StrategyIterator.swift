//
//  StrategyIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/7/2025.
//

protocol AnyStrategyIterator {
    associatedtype Convertible
    
    func next() -> ChoiceTree?
}

final class StrategyIterator<T: BitPatternConvertible>: IteratorProtocol, AnyStrategyIterator {
    typealias Convertible = T

    private var current: T
    let strategy: any TemporaryDualPurposeStrategy
    let nextValue: (T) -> T?
    let output: (T) -> ChoiceTree?
    
    init(initial: T, strategy: any TemporaryDualPurposeStrategy, _ transform: @escaping (T) -> T?, output: @escaping (T) -> ChoiceTree?) {
        self.current = initial
        self.strategy = strategy
        self.nextValue = transform
        self.output = output
    }
    
    func next() -> ChoiceTree? {
        guard let this = nextValue(current) else {
            print("Failed to pull from \(Self.self)/\(type(of: strategy)).\(strategy.direction) \(self.output) \(current)")
            return nil
        }
        print("Pulled from \(Self.self)/\(type(of: strategy)).\(strategy.direction) \(current) -> \(this)")
        current = this
        return output(this)
    }
}
