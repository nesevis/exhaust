// The operations are only generic over its inputs. The type of output is contained within the continuation of the containing ReflectiveGen
enum ReflectiveOperation<Input> {
    // A case for Lmap.
    // We need type erasure here because Swift enums can't change type parameters across cases.
    case lmap(transform: (Input) -> Any, next: ReflectiveGen<Any, Any>)
    
    // A case for Pick.
    case pick(choices: [(weight: Int, choice: String, generator: ReflectiveGen<Input, Any>)])
    
    // A case for Prune.
    // Handles failures in the backwards/reflect pass
    // TODO: We may be able to preserve the input type here by wrapping it in Optional<>
    case prune(next: ReflectiveGen<Any, Any>)
    // This is tricky. In Haskell, prune changes the `b` parameter to `Maybe b`.
    // In Swift, you might need another layer of erasure.
    // ... other cases like chooseInteger, getSize etc.
    
    /// Gets the current size parameter from the context. The Output must be UInt64.
    /// TODO: Remove. Does not work with reflect
    case getSize
    
    // TODO: add `from`?
    case chooseBits(min: UInt64, max: UInt64)
    
    // Provides reflective capabilities for how to extract a partial value from the input
    case lens(any PartialPath, next: ReflectiveGen<Input, Any>)
    
    case sequence(length: UInt64, gen: ReflectiveGen<Input, Any>)
}
