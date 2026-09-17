import ExhaustCore

/// Prebuilds one generator per distinct size key so sizes that share a key share a completed generator, then selects by the active size.
///
/// The caller owns the policy that maps a size in 1...100 to a key. This owns the memoization, the clamp, and the `getSize` bind. Every layer is built when this is called, so the caller's ceiling determines construction cost. Reflection support is the conjunction over the built layers.
func sizeIndexedLayers<Key: Hashable, Value>(
    key: (Int) -> Key,
    build: (Key) -> ReflectiveGenerator<Value>
) -> ReflectiveGenerator<Value> {
    var completed: [Key: ReflectiveGenerator<Value>] = [:]
    let layers = (1 ... 100).map { size -> ReflectiveGenerator<Value> in
        let sizeKey = key(size)
        if let existing = completed[sizeKey] {
            return existing
        }
        let generator = build(sizeKey)
        completed[sizeKey] = generator
        return generator
    }
    return Gen.getSize { size in layers[Int(min(100, max(1, size))) - 1].gen }.wrapped(
        isReflective: layers.allSatisfy { $0.isReflective }
    )
}
