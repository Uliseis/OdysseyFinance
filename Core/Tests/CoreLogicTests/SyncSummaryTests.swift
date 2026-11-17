import XCTest
import SwiftData
import CoreModel
@testable import CoreLogic

final class SyncSummaryTests: XCTestCase {
    private typealias Summary = CoreLogic.SyncSummary
    private typealias Report = CoreLogic.EBSync.Report
    private typealias Outcome = CoreLogic.InvestmentRefresh.Outcome
    private typealias S = TransferTestSupport

    private func valued(_ count: Int, of live: Int? = nil, failures: [String] = []) -> Outcome {
        Outcome(updated: (0..<count).map { _ in UUID() }, failures: failures, liveAccounts: live ?? count)
    }

    private func synced(_ count: Int, new: Int = 0, problems: [String] = []) -> Summary.Banks {
        .synced(Report(synced: count, newTransactions: new, problems: problems))
    }

    func testBothPartsDone() {
        XCTAssertEqual(Summary.text(banks: synced(3), investments: valued(2)),
                       "Banks synced (3), investments refreshed (2).")
        XCTAssertEqual(Summary.text(banks: synced(2, new: 1), investments: valued(1)),
                       "Banks synced (2, 1 new transaction), investments refreshed (1).")
        XCTAssertEqual(Summary.text(banks: synced(2, new: 5), investments: valued(1)),
                       "Banks synced (2, 5 new transactions), investments refreshed (1).")
    }

    // The last try may have failed at the bank, so a skip never claims the banks synced.
    func testBanksSkippedStillSaySo() {
        XCTAssertEqual(Summary.text(banks: .recent, investments: valued(2)),
                       "Banks skipped (last tried under 15 minutes ago), investments refreshed (2).")
        XCTAssertEqual(Summary.text(banks: .busy, investments: valued(2)),
                       "Banks already syncing, investments refreshed (2).")
    }

    func testABankNeedingAttentionComesAfterWhatWasDone() {
        let reconnect = "Bank B needs reconnecting in Settings"
        XCTAssertEqual(Summary.text(banks: synced(1, problems: [reconnect]), investments: valued(2)),
                       "Banks synced (1), investments refreshed (2). Bank B needs reconnecting in Settings.")
        XCTAssertEqual(Summary.text(banks: synced(0, problems: [reconnect, "another"]), investments: valued(2)),
                       "Investments refreshed (2). Banks not synced. Bank B needs reconnecting in Settings.")
    }

    func testAnUnreadableBankKey() {
        XCTAssertEqual(Summary.text(banks: .noKey("The bank key can't be read until the iPhone is unlocked after a restart"), investments: valued(1)),
                       "Investments refreshed (1). Banks not synced. The bank key can't be read until the iPhone is unlocked after a restart.")
        XCTAssertEqual(Summary.text(banks: .noKey("Add the Enable Banking key in Settings"), investments: valued(1)),
                       "Investments refreshed (1). Banks not synced. Add the Enable Banking key in Settings.")
    }

    func testTheFirstInvestmentFailure() {
        let noKey = "Funds: add the EODHD key in Settings; not saved."
        XCTAssertEqual(Summary.text(banks: synced(2), investments: valued(0, of: 1, failures: [noKey, "more"])),
                       "Banks synced (2). Investments not refreshed. Funds: add the EODHD key in Settings; not saved.")
        XCTAssertEqual(Summary.text(banks: synced(2), investments: valued(1, of: 2, failures: ["Trading 212: add the API key in Settings"])),
                       "Banks synced (2), investments refreshed (1). Trading 212: add the API key in Settings.")
        XCTAssertEqual(Summary.text(banks: synced(1), investments: valued(0, of: 1)),
                       "Banks synced (1), no new investment values.")
    }

    func testOnlyWhatIsSetUpIsMentioned() {
        XCTAssertEqual(Summary.text(banks: .notConnected, investments: valued(2)), "Investments refreshed (2).")
        XCTAssertEqual(Summary.text(banks: synced(2), investments: valued(0, of: 0)), "Banks synced (2).")
        XCTAssertEqual(Summary.text(banks: .notConnected, investments: valued(0, of: 0)),
                       "Nothing to sync: no bank or live-priced investment account is set up.")
    }

    // MARK: - Bank report

    @MainActor
    func testTheReportCountsCleanSyncsAndPutsReconnectionsFirst() throws {
        let ctx = try S.makeContext()
        func connection(_ name: String, _ status: ConnectionStatus, session: String? = "session") -> Connection {
            let c = Connection(connector: .enablebanking, institutionName: name, sessionId: session, status: status)
            ctx.insert(c)
            return c
        }
        let clean = connection("Bank A", .active)
        let failing = connection("Bank B", .error)
        _ = connection("Bank C", .expired)
        let abandoned = connection("Bank D", .pending, session: nil)
        try ctx.save()

        var ok = CoreLogic.EBSync.SyncResult(connectionId: clean.id)
        ok.transactionsInserted = 2
        var failed = CoreLogic.EBSync.SyncResult(connectionId: failing.id)
        failed.transactionsInserted = 1
        failed.errors = ["acct: timed out"]
        var noSession = CoreLogic.EBSync.SyncResult(connectionId: abandoned.id)
        noSession.errors = ["noSession"]

        let report = CoreLogic.EBSync.report([ok, failed, noSession], in: ctx)

        XCTAssertEqual(report.synced, 1)
        XCTAssertEqual(report.newTransactions, 3)
        XCTAssertEqual(report.problems, [
            "Bank C needs reconnecting in Settings",
            "Bank B didn't sync; its connection in Settings shows why",
        ], "a connection never finished isn't a sync problem")
    }
}
