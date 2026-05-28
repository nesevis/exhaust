extension Optional: ExhaustGenerable where Wrapped: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let typedInner: Generator<Wrapped> = Wrapped.defaultGenerator.map { $0 as! Wrapped }
        return Gen.pick(choices: [
            (1, Gen.just(Wrapped?.none)),
            (4, typedInner.liftToOptional()),
        ]).erase()
    }
}

extension Array: ExhaustGenerable where Element: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let typedElement: Generator<Element> = Element.defaultGenerator.map { $0 as! Element }
        return Gen.arrayOf(typedElement).erase()
    }
}

extension Dictionary: ExhaustGenerable where Key: ExhaustGenerable, Value: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let typedKey: Generator<Key> = Key.defaultGenerator.map { $0 as! Key }
        let typedValue: Generator<Value> = Value.defaultGenerator.map { $0 as! Value }
        return Gen.dictionaryOf(typedKey, typedValue).erase()
    }
}

extension Set: ExhaustGenerable where Element: ExhaustGenerable {
    package static var defaultGenerator: AnyGenerator {
        let typedElement: Generator<Element> = Element.defaultGenerator.map { $0 as! Element }
        return Gen.setOf(typedElement).erase()
    }
}
