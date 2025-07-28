//
//  StrategySequenceIterator.swift
//  Exhaust
//
//  Created by Chris Kolbu on 28/7/2025.
//

final class StrategySequenceIterator: IteratorProtocol, AnyStrategyIterator {
    typealias Convertible = [ChoiceTree]
    let nextValues: (Convertible.SubSequence) -> [Convertible.SubSequence]?
    let output: (Convertible.SubSequence) -> ChoiceTree?
    private var initial: Convertible.SubSequence
    private var currentBatch: [Convertible.SubSequence].SubSequence?

    init(initial: Convertible, _ transform: @escaping (Convertible.SubSequence) -> [Convertible.SubSequence]?, output: @escaping (Convertible.SubSequence) -> ChoiceTree?) {
        // The sequence to use as a basis
        self.initial = initial[...]
        // The transform that returns a sequence of sequences as alternatives
        self.nextValues = transform
        // The transform for each of these sequences into a new sequence for the shrinker
        self.output = output
    }
    
    func next() -> ChoiceTree? {
        if currentBatch?.first == nil, let next = nextValues(initial) {
            currentBatch = next[...]
        }
        // Now return the
        guard let next = currentBatch?.first else {
            return nil
        }
        print("Pulled from \(Self.self) \(next)")
        currentBatch = currentBatch?.dropFirst()
        return output(next)
    }
}
