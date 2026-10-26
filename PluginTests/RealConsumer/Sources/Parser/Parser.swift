public enum Parser {
    // Keep a real call into the fixture so the smoke test observes both instrumented modules. The guard and the separate rejection function give the library its own edges: a bare comparison compiles to a single block, so without them the library contributes one edge and coverage depends on the test target being instrumented too, which Windows campaigns skip.
    @inline(never)
    public static func accepts(_ value: Int) -> Bool {
        guard value >= 10 else {
            return rejects(value)
        }
        return true
    }

    @inline(never)
    static func rejects(_ value: Int) -> Bool {
        false
    }
}
