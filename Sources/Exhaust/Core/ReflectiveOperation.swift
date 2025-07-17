// The operations are only generic over its inputs. The type of output is contained within the continuation of the containing ReflectiveGen
enum ReflectiveOperation<Input> {
    // A case for Lmap.
    // We need type erasure here because Swift enums can't change type parameters across cases.
    case lmap(transform: (Any) -> Any?, next: ReflectiveGen<Any, Any>)
    
    // A case for Pick.
    case pick(choices: [(weight: UInt64, label: UInt64, generator: ReflectiveGen<Input, Any>)])
    
    // A case for Prune.
    // Handles failures in the backwards/reflect pass
    // TODO: We may be able to preserve the input type here by wrapping it in Optional<>
    case prune(next: ReflectiveGen<Any, Any>)
    // This is tricky. In Haskell, prune changes the `b` parameter to `Maybe b`.
    // In Swift, you might need another layer of erasure.
    
    // TODO: add `from`?
    case chooseBits(min: UInt64, max: UInt64)
    
    // Represents an arbitrary collection of values
    case sequence(length: UInt64, gen: ReflectiveGen<Input, Any>)
}
