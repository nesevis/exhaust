//
//  AdaptationInterpreter.swift
//  Exhaust
//
//  Created by Chris Kolbu on 17/8/2025.
//

import Foundation

enum AdaptationInterpreter {
    // TODO: Take a ChoiceTree and a Generator and walk a value through it, materialising all pick options and applying the transformations of branch weight and choice -> pick of choices
    // TODO:
    
    // Should we use a SerializableKeypath to lens directly in to the original generator to set the new weights determined by the derivatives?
    
    // What does the use look like?
    // Interpreters.adapt(gen, tree) { gen, tree in
         // if this is a pick,
         // else return nil to
    // }
    
    // Do we pass in depth, or make it computable from the path?
    enum AdaptationResult<Output> {
        // A single generator in the chain was changed, e.g creating a pick of subranges from a choice value
        case adapted(path: SerializableChoiceTreePath<Output>, target: ReflectiveGenerator<Output>)
        // Derivatives, e.g `picks` reduced to a single branch, have been created and should be tested
        // The `SerializableKeyPath` will provide a lens into the specific location of these particular picks
        // TODO: Should it be [(path, gen)]?
        case derivatives(path: SerializableChoiceTreePath<Output>, targets: [ReflectiveGenerator<Output>])
        // Keep going, but keep appending to the tree path
        case unchanged(path: SerializableChoiceTreePath<Output>)
        // Early return
        case terminate
    }
    
    /*
     NOTE!
     We wouldn't be able to lens into a generator in the way that we have described so far.
     Because of opaque bind chains, we have to walk it to access the resulting generator from executing the continuation with a valid value. Even then, if there's an if-else in that continuation we won't be able to apply CGS properly.
     
     So the transform is (depth, tree) -> ReflectiveGenerator<Output> — BUT!
     We've now found the generator we would like to create a derivative of, but we are now somewhere like this
     [entrypoint]...[n/a]...[n/a]...<target generator, continuation>...?
     // The thinking below this point is forgetting that we are in a recursive chain that means that the "here" is reflective of where the optimisation is taking place.
     So we have access to the target generator, but to fully execute the generator we will need to start from the entrypoint, so effectively we'll have to walk GenA with a ChoiceTree and build up GenA-2 as we go. Once we hit a derivation point, we complete the generator by wrapping it in an impure with the same continuation, then execute it against sampleN to discover the new weight. While still in the closure, we then modify the reflectiveOperation to apply the new sample-adjusted weights, then return the CGSed generator.
    Or do we even return? Do we keep going until we run out of significant sampleN? So this is all done in one (slow) walk of the generator, ultimately returning GenA-2? Yes! It happens in a single walk of the original generator!
     `.map`s result in a `.pure(transform($0))`, so we need to be handling it as well. Opaque as it might be, a value transformation is a value transformation
     
     */
    
    // Effectively lets you map over a generator as it's being walked
    static func adapt<Input, Output>(
        original: ReflectiveGenerator<Output>,
        input: Input, // In case this is a specific type of generator that requires an input
        samples: UInt64 = 100, // Samples at depth = 0
        choiceTree: ChoiceTree,
        // We could stash away the valid results in an `inout` here to benefit from the sampling work?
        _ validityPredicate: @escaping (Output) -> Bool // The function we're testing against
    ) throws -> ReflectiveGenerator<Output> {
        let context = Context(choiceTree: choiceTree, sampleBase: samples)
        let _ = try adaptRecursive(gen: original, input: input, context: context) { untyped in
            guard let output = untyped as? Output else {
                throw AdaptationError.typeMismatch(expected: "\(Output.self)", actual: "\(type(of: untyped))")
            }
            return validityPredicate(output)
        }
        return context.adaptedPartialGenerator!.map { $0 as! Output }
    }
    
    static func adaptRecursive<Input, Output>(
        gen: ReflectiveGenerator<Output>,
        input: Input,
        context: Context,
        _ validityPredicate: @escaping (Any) throws -> Bool
    ) throws -> ReflectiveGenerator<Output> {
        switch gen {
        case .pure:
            if let partialGen = context.adaptedPartialGenerator {
                  return partialGen.bind { result in .pure(result as! Output) }
              } else {
                  return gen
              }
        case let .impure(op, continuation):
            let runContinuation = { (op: ReflectiveOperation, input: Any) throws -> ReflectiveGenerator<Output> in
                // What are we doing in here? Increasing depth, or should that only be increased when we transform a choice value or a pick? Probably? Maybe not, as structural importance is measured by depth?
                let nextGen = try continuation(input)
                if context.adaptedPartialGenerator == nil {
                    context.adaptedPartialGenerator = .impure(operation: op) { _ in nextGen.erase() }
                }
                else {
                    context.adaptedPartialGenerator = context.adaptedPartialGenerator!.bind { _ in
                        .impure(operation: op) { _ in nextGen.erase() }
                    }
                }
                // Keep executing it?
                return try adaptRecursive(gen: nextGen, input: input, context: context, validityPredicate)
            }
            switch op {
            case let .contramap(transform, next):
                let nextGen = try adaptRecursive(gen: next, input: input, context: context, validityPredicate)
                return try runContinuation(.contramap(transform: transform, next: nextGen), input)
            case let .pick(choices):
                context.depth += 1
                var newChoices = choices
                // This is where the CGS wonder happens
                
                let sampleRate = context.sampleBase / context.depth
                
                var anyInput: Any? = nil
                for index in choices.indices {
                    let choice = newChoices[index]
                    // How do we reconstruct the full generator here?
                    let fullGen = context.adaptedPartialGenerator?.bind { result in
                            .impure(operation: .pick(choices: [choice])) { _ in
                                try continuation(result).erase()
                            }
                    } ?? choice.generator
                    
                    var valueInterpreter = ValueInterpreter(fullGen, maxRuns: sampleRate)
                    var passes: UInt64 = 0
                    while let next = valueInterpreter.next() {
                        passes += try validityPredicate(next) ? 1 : 0
                        anyInput = anyInput ?? next
                        context.runs += 1
                    }
                    newChoices[index] = (passes, choice.label, choice.generator)
                }
                // The problem here is that we're not passing the 'correct' input to the continuation
                // And effectively materialise it so that it becomes fixed to a `anyInput`.
                return try runContinuation(.pick(choices: newChoices), input)
            case let .prune(next):
//                let nextGen = try adaptRecursive(gen: next, input: input, context: context, validityPredicate)
                return try runContinuation(op, input)
            case .chooseBits:
                // Fork into subranges. This needs to be type aware
                return try runContinuation(op, input)
            case let .sequence(lengthGen, gen):
                // TODO: Fork length into subranges. This is a UInt64 range
                context.depth += 1
                return try runContinuation(op, input)
            case let .zip(gens):
                var newGens = gens
                for index in gens.indices {
                    newGens[index] = try adaptRecursive(gen: gens[index], input: input, context: context, validityPredicate)
                }
                return try runContinuation(.zip(newGens), input)
            case .just:
                // What do we do here?
                return try runContinuation(op, input)
            case .getSize:
                return try runContinuation(op, input)
            case let .resize(newSize, next):
                let nextGen = try adaptRecursive(gen: next, input: input, context: context, validityPredicate)
                return try runContinuation(.resize(newSize: newSize, next: nextGen), input)
            case let .filter(gen, fingerprint, predicate):
                let nextGen = try adaptRecursive(gen: gen, input: input, context: context, validityPredicate)
                return try runContinuation(.filter(gen: nextGen, fingerprint: fingerprint, predicate: predicate), input)
            case let .classify(gen, fingerprint, classifiers):
                let nextGen = try adaptRecursive(gen: gen, input: input, context: context, validityPredicate)
                return try runContinuation(.classify(gen: nextGen, fingerprint: fingerprint, classifiers: classifiers), input)
            }
        }
    }
    
    // MARK: - Context
    
    final class Context {
        /// The work in progress
        var adaptedPartialGenerator: ReflectiveGenerator<Any>?
        /// The choiceTree — the map
        let choiceTree: ChoiceTree
        /// The number of samples at relevant depth = 1
        let sampleBase: UInt64
        /// The current depth:
        var depth: UInt64 = 0
        /// The number of samples run
        var runs: UInt64 = 0
        
        
        init(
            choiceTree: ChoiceTree,
            sampleBase: UInt64,
            depth: UInt64 = 0,
            runs: UInt64 = 0
        ) {
            self.choiceTree = choiceTree
            self.sampleBase = sampleBase
            self.depth = depth
            self.runs = runs
        }
    }
    
    public enum AdaptationError: LocalizedError {
        case typeMismatch(expected: String, actual: String)
    }
}
