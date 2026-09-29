/// The scopes reflection carries down the generator spine and that individual operations forward unchanged.
///
/// Nearly every backward interpreter only passes this along, so a new scope costs one field here rather than a parameter on all of them. Values are passed by copy, which is what restores an outer scope when a nested call returns.
struct ReflectionContext {
    /// True while reflecting inside a pick arm, where a node's reported value decides which arm the pick selects. Nodes whose reported value would otherwise echo the target unchanged (`metamorphic`) rebuild it from the reflected original there, and only there, so top-level reflection keeps its contract of never running user transforms.
    var isProbingPickArm = false

    /// The size fixed by the innermost enclosing ``ReflectiveOperation/resize(newSize:next:)``. A `nil` size preserves reflection's size-100 default, which lets size-dependent generators expose their full range.
    var sizeOverride: UInt64?
    /// Keeps only a pick's first matching arm and path. Enumerating every arm is exponential in depth when arms overlap recursively.
    var stopsAtFirstMatchingArm = false
    /// Picks with this fingerprint reflect as producing nothing, so a search cannot recurse through that call site.
    var excludedPickFingerprint: UInt64?

    /// Outside every pick arm and every resize, which is where a top-level reflection starts.
    static let root = Self()

    /// Enters a pick arm.
    func enteringPickArm() -> Self {
        var entered = self
        entered.isProbingPickArm = true
        return entered
    }

    /// Enters a resize scope.
    func resized(to newSize: UInt64) -> Self {
        var entered = self
        entered.sizeOverride = newSize
        return entered
    }
}
