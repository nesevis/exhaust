enum Gen {
    static func liftF<Input, Output>(
        _ op: ReflectiveOperation<Input>
    ) -> ReflectiveGen<Input, Output> {
        return .impure(operation: op) { result in
            guard let typedResult = result as? Output else {
                fatalError("Interpreter provided wrong type. Expected \(Output.self), got \(type(of: result))")
            }
            return .pure(typedResult)
        }
    }
    
    static func pick<Output>(
        choices: [(weight: Int, choice: String?, generator: ReflectiveGen<Void, Output>)]
    ) -> ReflectiveGen<Void, Output> {
        // The nested generators must all have the same Output type.
        // We erase it to `Any` for the operation, but the `liftF` call
        // ensures the final monad has the correct `Output` type.
        let erasedChoices = choices.map { ($0.weight, $0.choice, $0.generator.map { $0 as Any }) }
        return liftF(.pick(choices: erasedChoices))
    }
    
    static func prune<Input, Output>(_ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<Optional<Input>, Output> {
        // The implementation is very similar to lmap: it uses mapOperation to erase
        // the input type and wraps the generator in the .prune operation.
        let erasedGenerator = generator.mapOperation(eraseInputType).map { $0 as Any }
        
        let op = ReflectiveOperation<Optional<Input>>.prune(next: erasedGenerator)
        
        return liftF(op)
    }
    
    // The transformation function that changes the Operation's Input type to Any.
    // This function needs to be defined recursively for the `.pick` case.
    static func eraseInputType<Input>(from op: ReflectiveOperation<Input>) -> ReflectiveOperation<Any> {
        switch op {
        case .pick(let choices):
            let result = choices.map { ($0.weight, $0.choice, $0.generator.mapOperation(eraseInputType(from:))) }
            return .pick(choices: result)
        case let .prune(next):
            return .prune(next: next)
        case .lmap(let transform, let next):
            // This case is tricky because it's already partially erased.
            // A simple way to handle it is to create a new transform from Any.
            // Note: This reveals a slight awkwardness in the enum design, but it works.
            let newTransform: (Any) -> Any = { anyInput in
                guard let typedInput = anyInput as? Input else {
                    fatalError("Type mismatch during lmap erasure.")
                }
                return transform(typedInput)
            }
            return .lmap(transform: newTransform, next: next)
        case .getSize:
            return .getSize
        case let .resize(to, next):
            let newNext = next.mapOperation(eraseInputType(from:))
            return .resize(to: to, next: newNext)
        case let .chooseBits(min, max):
            return .chooseBits(min: min, max: max)
        case let .zip(a, b):
            return .zip(
                a.mapOperation(eraseInputType(from:)),
                b.mapOperation(eraseInputType(from:))
            )
        }
    }
    
    static func choose<T: BitPatternConvertible & Strideable>(
        in range: Range<T>
    ) -> ReflectiveGen<Void, T> where T.Stride : SignedInteger {
        
        // 1. Determine the effective upper bound. For a range `a..<b`, the last
        //    integer value is `b - 1`. The `advanced(by: -1)` method is the
        //    generic way to do this for any Strideable type.
        let inclusiveUpperBound = range.upperBound.advanced(by: -1)
        
        // 2. Check that the resulting range is valid.
        precondition(range.lowerBound <= inclusiveUpperBound, "The range is empty or invalid")
        
        // 3. Create a new *ClosedRange* from the calculated bounds.
        let inclusiveRange = range.lowerBound...inclusiveUpperBound
        
        // 4. Delegate to the existing `choose(in: ClosedRange<T>)` function.
        //    This avoids code duplication and keeps the core logic in one place.
        return choose(in: inclusiveRange)
    }
    
    static func choose<T: BitPatternConvertible>(in range: ClosedRange<T>? = nil, type: T.Type = T.self) -> ReflectiveGen<Void, T> {
        
        // 1. Determine the range of raw UInt64 bits to generate.
        //    This logic delegates the responsibility of defining the range to the type `T` itself.
        //    For example, for `Int`, this will now be the full `UInt64` range to support negatives.
        let minBits = range?.lowerBound.bitPattern64 ?? T.bitPatternRange.lowerBound
        let maxBits = range?.upperBound.bitPattern64 ?? T.bitPatternRange.upperBound

        // 2. Create the unified, type-agnostic operation. The interpreter only needs to know
        //    how to generate a UInt64 within these bounds.
        let op = ReflectiveOperation<Void>.chooseBits(min: minBits, max: maxBits)
        
        // 3. Construct the FreerMonad by embedding the type-specific decoding logic
        //    inside the continuation. This is the core of the design.
        return .impure(operation: op) { result in
            // a. The interpreter will execute the operation and pass the raw `UInt64` result here.
            guard let convertible = result as? (any BitPatternConvertible) else {
                // This signifies a bug in the interpreter, not user code.
                fatalError("Interpreter failed to provide a UInt64 for a chooseBits operation.")
            }
            
            // b. The continuation uses the protocol's required initializer to convert the
            //    raw bits back into the final, strongly-typed `T`. This is where the
            //    magic of two's complement or IEEE 754 happens, specific to type `T`.
            // Kolbu: This works both in generate and reflect
            let finalValue = T(bitPattern: convertible.bitPattern64)
            
            // c. Wrap the final value in `.pure` to complete this branch of the monadic computation.
            return .pure(finalValue)
        }
    }
    
    static func lmap<NewInput, Input, Output>(_ transform: @escaping (NewInput) -> Input, _ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<NewInput, Output> {
        
        let erasedTransform: (NewInput) -> Any = { newInput in
            transform(newInput) as Any
        }
        
        let erasedGen = generator
            .mapOperation { eraseInputType(from: $0) }
            .map { $0 as Any }

        return .impure(operation: ReflectiveOperation.lmap(transform: erasedTransform, next: erasedGen)) { _ in
            // This continuation should not be called in a correct interpreter for lmap
            fatalError("Lmap's continuation should be handled by the interpreter.")
        }
    }
    
    static func comap<NewInput, Input, Output>(
        _ transform: @escaping (NewInput) -> Input?,
        _ generator: ReflectiveGen<Input, Output>
    ) -> ReflectiveGen<NewInput, Output> {
        
        let lmapGen = lmap({ (input: NewInput) -> Input? in
            transform(input)
        }, prune(generator))
        
        return lmapGen
    }
    
    // A base generator that produces a single, constant value.
    static func just<Output>(_ value: Output) -> ReflectiveGen<Any, Output> {
        return .pure(value)
    }

    // exact is the canonical leaf generator. It generates a constant value and, crucially, in the backward pass, it fails if the input doesn't match that constant.
    static func exact<Value: Equatable>(_ value: Value) -> ReflectiveGen<Value, Value> {
        // 1. Start with a generator that just produces the value.
        let baseGenerator = just(value)
        
        // 2. Use `comap` to check for equality.
        // The transform returns the value if it matches, or nil otherwise.
        return comap({ (inputValue: Value) -> Value? in
            inputValue == value ? inputValue : nil
        }, baseGenerator)
    }
    
    /// Creates a generator that produces the current size from the interpreter's context.
    static func getSize() -> ReflectiveGen<Void, Int> {
        liftF(.getSize)
    }
    
    /// Creates a generator that runs a sub-generator within a context with a new size.
    static func resize<Input, Output>(to size: Int, _ generator: ReflectiveGen<Input, Output>) -> ReflectiveGen<Input, Output> {
        // Wrap the provided generator in the resize operation.
        let op = ReflectiveOperation<Input>.resize(to: size, next: generator.map { $0 as Any })
        
        // The continuation simply passes through the result of the inner generator.
        return liftF(op)
    }
    
    static func zip<Input, A, B>(
        _ genA: ReflectiveGen<Input, A>,
        _ genB: ReflectiveGen<Input, B>
    ) -> ReflectiveGen<Input, (A, B)> {
        
        // 1. Erase the output types of the sub-generators to `Any` so they can be
        //    stored in the `.zip` operation case.
        let erasedGenA = genA.map { $0 as Any }
        let erasedGenB = genB.map { $0 as Any }

        // 2. Create the `.zip` operation.
        let op = ReflectiveOperation<Input>.zip(erasedGenA, erasedGenB)
        
        let intermediate: ReflectiveGen<Input, (Any,Any)> = liftF(op)
        
        // 3. Lift the operation into a FreerMonad. The continuation defines how the
        //    interpreter's result (which will be `(Any, Any)`) is decoded.
        return intermediate.map { anyTuple -> (A, B) in
            // The interpreter will produce a tuple of `(Any, Any)`.
            // The continuation's job is to cast it back to the strong types `(A, B)`.
            guard let a = anyTuple.0 as? A,
                  let b = anyTuple.1 as? B else {
                fatalError("Type mismatch in zip continuation. This is an interpreter bug.")
            }
            return (a, b)
        }
    }
}
