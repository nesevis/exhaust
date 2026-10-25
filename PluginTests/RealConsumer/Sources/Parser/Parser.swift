public enum Parser {
    // Keep a real call into the fixture so the smoke test observes both instrumented modules.
    @inline(never)
    public static func accepts(_ value: Int) -> Bool {
        value >= 10
    }
}
