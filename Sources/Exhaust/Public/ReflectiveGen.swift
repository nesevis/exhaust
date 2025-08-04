//
//  ReflectiveGen.swift
//  Exhaust
//
//  Created by Chris Kolbu on 4/8/2025.
//

protocol AnyGenerator {
    associatedtype Input
    associatedtype Output
}

// There's no way for us to really limit the composition that user can do. `bind` is also opaque and can transform its output before it's passed to the generator, which could mean replay wouldn't be deterministic?

struct ReflectiveGen<Input, Output>: AnyGenerator {
    private let generator: ReflectiveGenerator<Input, Output>
}

struct OneWayGen<Input, Output>: AnyGenerator {
    private let generator: ReflectiveGenerator<Input, Output>
}
