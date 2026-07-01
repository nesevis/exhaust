import Exhaust
import Foundation
import Testing

@Suite("Preemptive linearizability: real race detection", .serialized, .tags(.contract))
struct PreemptiveRacyAccountTests {
    @Test("Detects lost update in unsynchronized counter")
    func detectsLostUpdateInUnsynchronizedCounter() async throws {
        var report: ExhaustReport?
        let result = try #require(
            await #execute(
                RacyAccountSpec.self,
                .concurrent(.two),
                .budget(.custom(coverage: 20000, sampling: 20000)),
                .suppress(.issueReporting),
                .idleTimeoutMs(30000),
                .onReport { report = $0 }
            )
        )
        print(report?.profilingSummary)
        print(result.replaySeed)
        print(result.trace)
        print(result.originalCommands)
        #expect(result.replaySeed != nil)
        #expect(result.commands.count >= 2, "Need at least 2 concurrent commands to trigger the race")
    }
}

// MARK: - Spec

/// Account where deposits are atomic but withdrawals race.
///
/// The `withdraw` path does an unsynchronized read-modify-write, so two concurrent withdrawals can both read the same balance and each subtract from it, losing an update.
/// The `deposit` path is lock-protected, so a sequence of deposits must run before any withdrawal is valid. This forces the reducer to keep some prefix commands and gives the pipeline enough depth to exercise lane-collapse before the linearizability check.
@Contract(.threads)
final class RacyAccountSpec {
    @SystemUnderTest
    var account: RacyAccount = .init()

    @Oracle
    func balanceMatches(other: RacyAccount) -> Bool {
        account.balance == other.balance
    }

    @Command(weight: 3, .int(in: 1 ... 10))
    func deposit(amount: Int) {
        account.deposit(amount)
    }

    @Command(weight: 2, .int(in: 1 ... 5))
    func withdraw(amount: Int) throws -> Int {
        guard account.balance >= amount else { throw skip() }
        account.withdraw(amount)
        return amount
    }

    func failureDescription() -> String? {
        "balance: \(account.balance)"
    }
}

// MARK: - SUT

/// Account with atomic deposits but racy withdrawals.
///
/// `deposit` is lock-protected. `withdraw` deliberately skips the lock,
/// so two concurrent withdrawals both read the same balance and each
/// subtract independently, losing one update.
final class RacyAccount: @unchecked Sendable {
    private let lock = NSLock()
    private var _balance: Int = 0

    var balance: Int {
        lock.withLock { _balance }
    }

    func deposit(_ amount: Int) {
        lock.withLock { _balance += amount }
    }

    func withdraw(_ amount: Int) {
        let current = _balance
        Thread.sleep(forTimeInterval: 0.0001)
        _balance = current - amount
    }
}
