import ExecuteFixture
import Testing

@Suite("PhaseSession reproducer smoke tests")
struct PhaseSessionSmokeTests {
    // MARK: - Fault O (order-gated: cycles, then use while closed)

    @Test("Fault O fires after five completed cycles and a stray use (registry minimal)")
    func faultOMinimal() {
        var session = PhaseSession()
        for _ in 0 ..< 5 {
            session.open()
            session.use()
            session.close()
        }
        session.use()
        #expect(session.isCorrupted, "five completed cycles followed by use-while-closed should fire fault O")
    }

    @Test("Fault O does not fire after four completed cycles (strict prefix)")
    func faultOPrefixSafe() {
        var session = PhaseSession()
        for _ in 0 ..< 4 {
            session.open()
            session.use()
            session.close()
        }
        session.use()
        #expect(session.isCorrupted == false, "four cycles are below the threshold")
    }

    @Test("Fault O does not fire when the stray use lands while open")
    func faultONeedsClosedPhase() {
        var session = PhaseSession()
        for _ in 0 ..< 5 {
            session.open()
            session.use()
            session.close()
        }
        session.open()
        session.use()
        #expect(session.isCorrupted == false, "use while open is productive, not the fault trigger")
    }

    @Test("Fault O does not fire when reset intervenes")
    func faultOResetClearsProgress() {
        var session = PhaseSession()
        for _ in 0 ..< 5 {
            session.open()
            session.use()
            session.close()
        }
        session.reset()
        session.use()
        #expect(session.isCorrupted == false, "reset zeroes the cycle count")
    }

    @Test("A close without a use in the open period completes no cycle")
    func closeWithoutUseCompletesNoCycle() {
        var session = PhaseSession()
        for _ in 0 ..< 5 {
            session.open()
            session.close()
        }
        session.use()
        #expect(session.cycleCount == 0, "open followed directly by close is not a completed cycle")
        #expect(session.isCorrupted == false)
    }

    @Test("A cycle completes through the configured phase too")
    func cycleThroughConfiguredPhase() {
        var session = PhaseSession()
        for _ in 0 ..< 5 {
            session.open()
            session.configure(3)
            session.use()
            session.close()
        }
        session.use()
        #expect(session.isCorrupted, "use while configured counts toward the cycle")
    }

    @Test("The laddered variant shares the flat variant's trigger")
    func ladderedVariantSameTrigger() {
        var session = PhaseSession(laddered: true)
        for _ in 0 ..< 5 {
            session.open()
            session.use()
            session.close()
        }
        session.use()
        #expect(session.isCorrupted, "laddered changes the coverage surface, never the trigger")
    }

    @Test("The laddered variant still fires at the rung cap")
    func ladderedVariantFiresAtRungCap() {
        var session = PhaseSession(laddered: true, requiredCycles: PhaseSession.ladderRungLimit)
        for _ in 0 ..< PhaseSession.ladderRungLimit {
            session.open()
            session.use()
            session.close()
        }
        session.use()
        #expect(session.isCorrupted, "requiredCycles at the rung cap is the highest trigger the laddered variant admits; the init precondition rejects anything above it")
    }

    @Test("Configure while closed does not open the session")
    func configureWhileClosedStaysClosed() {
        var session = PhaseSession()
        session.configure(7)
        #expect(session.phaseName == "closed")
        session.use()
        #expect(session.cycleCount == 0, "use while closed marks no cycle progress")
    }
}
