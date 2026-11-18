import XCTest
import SwiftData
import CoreModel
@testable import CoreLogic

@MainActor
final class RollbackTests: XCTestCase {
    private typealias S = TransferTestSupport

    // Built in a closure so nothing but the store holds the group: that's when it went missing.
    private func investmentAccount(_ ctx: ModelContext) throws -> Account {
        let group = AccountGroup(name: "Invest", kind: .investment)
        ctx.insert(group)
        let account = Account(group: group, externalId: "broker", type: .broker,
                              institution: "Broker", name: "Funds", currency: "EUR")
        ctx.insert(account)
        try ctx.save()
        return account
    }

    // On iOS 27 a rollback that undid an insert left the model it pointed at reading nil for its
    // other relationships until that model was fetched again, so a retried import found the
    // account outside its investment group.
    func testARollbackLeavesTheModelsItTouchedReadingTheirRelationships() throws {
        let ctx = try S.makeContext()
        let account = try investmentAccount(ctx)
        ctx.insert(FundTrade(account: account, isin: "XX0000000001", tradeDate: .now, side: .buy,
                             units: 10, amountEur: 100, importKey: "key"))

        ctx.rollbackRefetching()

        XCTAssertEqual(account.group?.kind, .investment)
        XCTAssertEqual(account.fundTrades.count, 0, "the insert is still undone")
        XCTAssertFalse(ctx.hasChanges)
    }

    func testARollbackStillUndoesChangedValues() throws {
        let ctx = try S.makeContext()
        let account = try investmentAccount(ctx)
        account.name = "Renamed"

        ctx.rollbackRefetching()

        XCTAssertEqual(account.name, "Funds")
        XCTAssertEqual(account.group?.name, "Invest")
    }
}
