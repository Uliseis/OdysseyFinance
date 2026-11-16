import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class FundTradesTests: XCTestCase {
    typealias S = TransferTestSupport
    typealias T = CoreLogic.FundTrades
    typealias F = CoreLogic.Funds

    private let header = "Fecha de la orden;ISIN;Importe estimado;Nº de participaciones;Estado"
    private let cashHeader = "Fecha de operación;Fecha de valor;Concepto;Importe;Divisa"
    private let a = "ZZ0000000A00"
    private let b = "ZZ0000000B09"
    private let c = "ZZ0000000C08"

    private func d(_ s: String) -> Decimal { Decimal(string: s)! }

    private func utcDay(_ y: Int, _ m: Int, _ dd: Int) -> Date {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: m, day: dd))!
    }

    // Lines newest first, as the export writes them.
    private func csv(_ lines: String...) -> String { ([header] + lines).joined(separator: "\n") }

    // Cash movements, newest first: operation day and Spanish-format amount, valued the same day.
    private func cash(_ lines: [(day: String, amount: String)], other: [String] = []) -> String {
        ([cashHeader] + other + lines.map { "\($0.day);\($0.day);EXAMPLE FUND;\($0.amount);EUR" }).joined(separator: "\n")
    }

    private func makeInvestmentAccount(_ ctx: ModelContext) throws -> Account {
        let group = AccountGroup(name: "Invest", kind: .investment)
        ctx.insert(group)
        let account = Account(group: group, externalId: "broker", type: .broker,
                              institution: "Broker", name: "Funds", currency: "EUR")
        ctx.insert(account)
        try ctx.save()
        return account
    }

    private func saved(_ ctx: ModelContext) throws -> [FundTrade] {
        try ctx.fetch(FetchDescriptor<FundTrade>()).sorted { ($0.importKey ?? "") < ($1.importKey ?? "") }
    }

    private func saved(_ ctx: ModelContext, key: String) throws -> FundTrade {
        try XCTUnwrap(try saved(ctx).first { $0.importKey == key }, key)
    }

    private func importError(_ body: () throws -> Void) -> T.ImportError? {
        do {
            try body()
            return nil
        } catch {
            return error as? T.ImportError
        }
    }

    func testTheFundsInTheseTestsHaveValidISINs() {
        for isin in [a, b, c] { XCTAssertTrue(F.isValidISIN(isin), isin) }
    }

    // MARK: - Import

    private var firstExport: String {
        csv("20/03/2030;\(a);125.00 EUR;12,000;Finalizada",
            "20/02/2030;\(a);205.00 EUR;20,000;Finalizada",
            "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada")
    }
    // Each order settled the next day for exactly its estimate.
    private var firstCash: String {
        cash([("21/03/2030", "125"), ("21/02/2030", "-205"), ("16/02/2030", "-50"), ("21/01/2030", "-100")])
    }

    func testFirstImportSavesEachDoneOrderWithItsSideAndKey() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        let summary = try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash,
                                         heldUnits: [a: 18, b: 5], into: acc, in: ctx)

        XCTAssertEqual(try saved(ctx).map(\.importKey), [
            "myinvestor:v1:2030-01-20:\(a):10:100#1",
            "myinvestor:v1:2030-02-15:\(b):5:50#1",
            "myinvestor:v1:2030-02-20:\(a):20:205#1",
            "myinvestor:v1:2030-03-20:\(a):12:125#1",
        ])
        XCTAssertEqual(try saved(ctx).map(\.side), [.buy, .buy, .buy, .sell])
        XCTAssertTrue(try saved(ctx).allSatisfy { $0.account?.id == acc.id && $0.switchGroupId == nil })
        XCTAssertEqual(try T.trades(for: acc, in: ctx), [
            F.Trade(isin: a, date: utcDay(2030, 1, 20), side: .buy, units: 10, amountEur: 100),
            F.Trade(isin: b, date: utcDay(2030, 2, 15), side: .buy, units: 5, amountEur: 50),
            F.Trade(isin: a, date: utcDay(2030, 2, 20), side: .buy, units: 20, amountEur: 205),
            F.Trade(isin: a, date: utcDay(2030, 3, 20), side: .sell, units: 12, amountEur: 125),
        ])
        XCTAssertEqual(summary, T.ImportSummary(
            inserted: 4, alreadyPresent: 0,
            skippedInProgress: 0, skippedCancelled: 0, skippedRejected: 0,
            matchedToCash: 4, switchPairs: 0, switchPairsAdded: 0,
            amountsCorrected: 0, amountsCorrectedEur: 0,
            positions: [
                // The sale takes the first lot (100) and 2 of the second's 20 units (20.50).
                F.Position(isin: a, units: 18, costEur: d("184.5"), realisedGainEur: d("4.5"), priceEur: nil),
                F.Position(isin: b, units: 5, costEur: 50, realisedGainEur: 0, priceEur: nil),
            ]))
    }

    func testImportingTheSameExportAgainAddsNothing() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash, heldUnits: [a: 18, b: 5], into: acc, in: ctx)
        let ids = try saved(ctx).map(\.id)

        let summary = try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash,
                                         heldUnits: [a: 18, b: 5], into: acc, in: ctx)

        XCTAssertEqual(summary.inserted, 0)
        XCTAssertEqual(summary.alreadyPresent, 4)
        XCTAssertEqual(summary.amountsCorrected, 0)
        XCTAssertEqual(try saved(ctx).map(\.id), ids)
        XCTAssertEqual(summary.positions.map(\.units), [18, 5])
    }

    func testALaterExportAddsOnlyItsNewOrdersAndKeepsIdenticalRowKeys() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: csv(
            "20/02/2030;\(a);50.00 EUR;5,000;Finalizada",
            "20/02/2030;\(a);50.00 EUR;5,000;Finalizada",
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
        ), movementsCSV: cash([("21/02/2030", "-50"), ("21/02/2030", "-50"), ("21/01/2030", "-100")]),
        heldUnits: [a: 20], into: acc, in: ctx)
        let identical = "myinvestor:v1:2030-02-20:\(a):5:50"
        let before = try saved(ctx)
        XCTAssertEqual(before.map(\.importKey), ["myinvestor:v1:2030-01-20:\(a):10:100#1", "\(identical)#1", "\(identical)#2"])

        // A third identical order placed later that day, and a new fund.
        let summary = try T.importOrders(ordersCSV: csv(
            "20/03/2030;\(b);300.00 EUR;30,000;Finalizada",
            "20/02/2030;\(a);50.00 EUR;5,000;Finalizada",
            "20/02/2030;\(a);50.00 EUR;5,000;Finalizada",
            "20/02/2030;\(a);50.00 EUR;5,000;Finalizada",
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
        ), movementsCSV: cash([("21/03/2030", "-300"), ("21/02/2030", "-50"), ("21/02/2030", "-50"),
                               ("21/02/2030", "-50"), ("21/01/2030", "-100")]),
        heldUnits: [a: 25, b: 30], into: acc, in: ctx)

        XCTAssertEqual(summary.inserted, 2)
        XCTAssertEqual(summary.alreadyPresent, 3)
        let after = try saved(ctx)
        XCTAssertEqual(after.map(\.importKey), [
            "myinvestor:v1:2030-01-20:\(a):10:100#1", "\(identical)#1", "\(identical)#2", "\(identical)#3",
            "myinvestor:v1:2030-03-20:\(b):30:300#1",
        ])
        XCTAssertEqual(Set(before.map(\.id)).subtracting(after.map(\.id)), [])
    }

    func testSameDayBuyAndSaleOfAFundReadBuyFirst() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        // Placed in this order: 8 units, then 5. The sale's key sorts first.
        try T.importOrders(ordersCSV: csv(
            "20/01/2030;\(a);5.00 EUR;5,000;Finalizada",
            "20/01/2030;\(a);8.00 EUR;8,000;Finalizada"
        ), movementsCSV: cash([("21/01/2030", "5"), ("21/01/2030", "-8")]), heldUnits: [a: 3], into: acc, in: ctx)

        XCTAssertEqual(try T.trades(for: acc, in: ctx), [
            F.Trade(isin: a, date: utcDay(2030, 1, 20), side: .buy, units: 8, amountEur: 8),
            F.Trade(isin: a, date: utcDay(2030, 1, 20), side: .sell, units: 5, amountEur: 5),
        ])
    }

    func testUnreadableFundsAreNamedAndNothingIsWritten() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: csv("20/01/2030;\(c);40.00 EUR;4,000;Finalizada"),
                           movementsCSV: cash([("20/01/2030", "-40")]), heldUnits: [c: 4], into: acc, in: ctx)
        let before = try saved(ctx).map(\.id)

        let error = importError {
            try T.importOrders(ordersCSV: csv(
                "20/04/2030;\(c);40.00 EUR;4,000;Finalizada",
                // a: the first order sells units bought before the export.
                "20/03/2030;\(a);10.00 EUR;10,000;Finalizada",
                "20/02/2030;\(a);10.00 EUR;10,000;Finalizada",
                "20/01/2030;\(a);30.00 EUR;30,000;Finalizada",
                // b: buy 10, then buy 5 and sell 5 in either order.
                "20/03/2030;\(b);5.00 EUR;5,000;Finalizada",
                "20/02/2030;\(b);5.00 EUR;5,000;Finalizada",
                "20/01/2030;\(b);10.00 EUR;10,000;Finalizada",
                "20/01/2030;\(c);40.00 EUR;4,000;Finalizada"
            ), movementsCSV: cashHeader, heldUnits: [a: 20, b: 10, c: 8], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unreadableFunds(noReading: [a], ambiguous: [b]))
        XCTAssertEqual(try saved(ctx).map(\.id), before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func testASideDisagreeingWithASavedTradeThrowsAndWritesNothing() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let orders = ["20/02/2030;\(a);110.00 EUR;10,000;Finalizada", "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"]
        let movements = cash([("20/02/2030", "-110"), ("20/01/2030", "-100")])
        try T.importOrders(ordersCSV: csv(orders[0], orders[1]), movementsCSV: movements,
                           heldUnits: [a: 20], into: acc, in: ctx)

        // Read with nothing held, the second order becomes a sale.
        let error = importError {
            try T.importOrders(ordersCSV: csv("20/03/2030;\(b);50.00 EUR;5,000;Finalizada", orders[0], orders[1]),
                               movementsCSV: movements, heldUnits: [b: 5], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .sideConflicts(["myinvestor:v1:2030-02-20:\(a):10:110#1"]))
        XCTAssertEqual(try saved(ctx).map(\.side), [.buy, .buy])
        XCTAssertEqual(try saved(ctx).map(\.isin), [a, a])
        XCTAssertFalse(ctx.hasChanges)
    }

    func testOnlyInvestmentAccountsTakeFundTrades() throws {
        let ctx = try S.makeContext()
        let cashGroup = AccountGroup(name: "Cash", kind: .cash)
        ctx.insert(cashGroup)
        let checking = S.makeAccount(ctx, name: "Checking")
        checking.group = cashGroup
        let ungrouped = S.makeAccount(ctx, name: "Loose")
        try ctx.save()

        for account in [checking, ungrouped] {
            let error = importError {
                try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash,
                                   heldUnits: [a: 18, b: 5], into: account, in: ctx)
            }
            XCTAssertEqual(error, .notInvestmentAccount, account.name)
        }
        XCTAssertEqual(try saved(ctx).count, 0)
    }

    func testUnfinishedOrdersAreCountedButNotSaved() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        let summary = try T.importOrders(ordersCSV: csv(
            "13/03/2030;\(a);100 EUR;;En curso",
            "12/03/2030;\(a);50 EUR;;Pendiente",
            "11/03/2030;\(b);70 EUR;7,000;Cancelada",
            "10/03/2030;\(a);100 EUR;12,5;Rechazada",
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
        ), movementsCSV: cash([("21/01/2030", "-100")]), heldUnits: [a: 10], into: acc, in: ctx)

        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.skippedInProgress, 2)
        XCTAssertEqual(summary.skippedCancelled, 1)
        XCTAssertEqual(summary.skippedRejected, 1)
        XCTAssertEqual(try saved(ctx).map(\.importKey), ["myinvestor:v1:2030-01-20:\(a):10:100#1"])
    }

    func testAFundHeldWithoutOrdersInTheExportRefusesIt() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // b and c were bought before the export's window; a fund held at zero doesn't count.
        let error = importError {
            try T.importOrders(ordersCSV: csv("20/01/2030;\(a);100.00 EUR;10,000;Finalizada"),
                               movementsCSV: cash([("21/01/2030", "-100")]),
                               heldUnits: [a: 10, c: d("12.5"), b: 4, "ZZ0000000D07": 0], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .heldWithoutOrders([b, c]))
        XCTAssertEqual(try saved(ctx).count, 0)
        XCTAssertFalse(ctx.hasChanges)
    }

    func testARestatedAmountThatWouldSaveAnOrderTwiceIsRefused() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash, heldUnits: [a: 18, b: 5], into: acc, in: ctx)
        let before = try saved(ctx).map { [$0.id.uuidString, $0.importKey ?? "", "\($0.amountEur)"] }

        // The broker restated one order's estimated amount: same units, a new key.
        let error = importError {
            try T.importOrders(ordersCSV: csv(
                "20/03/2030;\(a);125.00 EUR;12,000;Finalizada",
                "20/02/2030;\(a);205.50 EUR;20,000;Finalizada",
                "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
                "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
            ), movementsCSV: firstCash, heldUnits: [a: 18, b: 5], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unitsMismatch([a]))
        XCTAssertEqual(try saved(ctx).map { [$0.id.uuidString, $0.importKey ?? "", "\($0.amountEur)"] }, before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func testSavedTradesOfAFundTheExportLeavesOutMustStillMatchTheUnitsHeld() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: csv("20/01/2030;\(c);40.00 EUR;4,000;Finalizada"),
                           movementsCSV: cash([("20/01/2030", "-40")]), heldUnits: [c: 4], into: acc, in: ctx)

        // c is no longer held, but no sale of it is saved or in this export.
        let error = importError {
            try T.importOrders(ordersCSV: csv("20/02/2030;\(a);100.00 EUR;10,000;Finalizada"),
                               movementsCSV: cash([("20/02/2030", "-100")]), heldUnits: [a: 10], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unitsMismatch([c]))
        XCTAssertEqual(try saved(ctx).map(\.isin), [c])
        XCTAssertFalse(ctx.hasChanges)
    }

    func testArchivedAccountsAreRefused() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        acc.archived = true
        try ctx.save()

        let error = importError {
            try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash,
                               heldUnits: [a: 18, b: 5], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .archived)
        XCTAssertEqual(try saved(ctx).count, 0)
    }

    // A store opened read-only lets the import run up to its save, which then throws.
    func testAFailedSaveLeavesNoInsertedTradesCorrectionsOrSwitchGroupsPending() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FundTradesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = url.appendingPathComponent("store.sqlite")
        let schema = Schema(CoreModelSchema.allTypes)
        func open(allowsSave: Bool) throws -> ModelContext {
            ModelContext(try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, url: store, allowsSave: allowsSave, cloudKitDatabase: .none),
            ]))
        }

        let writer = try open(allowsSave: true)
        try T.importOrders(ordersCSV: csv(switchOrders[2]), movementsCSV: cash([("21/01/2030", "-1.000")]),
                           heldUnits: [a: 100], into: try makeInvestmentAccount(writer), in: writer)

        let ctx = try open(allowsSave: false)
        let acc = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Account>()).first)
        // Inserts the switch, groups its legs and corrects the saved buy to its real debit.
        XCTAssertThrowsError(try T.importOrders(
            ordersCSV: csv(switchOrders[0], switchOrders[1], switchOrders[2]),
            movementsCSV: cash([("21/01/2030", "-1.000,25")]), heldUnits: [b: 60], into: acc, in: ctx))

        // Only the context's pending changes are checked: after a failed save SwiftData's
        // model caches (the account's trades, the next fetch) still show what it tried to write.
        XCTAssertFalse(ctx.hasChanges)
        XCTAssertTrue(ctx.insertedModelsArray.isEmpty)
        XCTAssertTrue(ctx.changedModelsArray.isEmpty)
    }

    func testARetryAfterARolledBackImportInsertsTheTrade() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let key = "myinvestor:v1:2030-01-20:\(a):10:100#1"
        // What a failed import leaves on the account instance: an insert the rollback undid.
        ctx.insert(FundTrade(account: acc, isin: a, tradeDate: utcDay(2030, 1, 20), side: .buy,
                             units: 10, amountEur: 100, importKey: key))
        ctx.rollback()

        let summary = try T.importOrders(ordersCSV: csv("20/01/2030;\(a);100.00 EUR;10,000;Finalizada"),
                                         movementsCSV: cash([("21/01/2030", "-100")]),
                                         heldUnits: [a: 10], into: acc, in: ctx)

        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(try saved(ctx).map(\.importKey), [key])
    }

    func testTradesLeaveOutAnInsertTheRollbackUndid() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        ctx.insert(FundTrade(account: acc, isin: a, tradeDate: utcDay(2030, 1, 20), side: .buy,
                             units: 10, amountEur: 100, importKey: "myinvestor:v1:2030-01-20:\(a):10:100#1"))
        ctx.rollback()

        XCTAssertEqual(try T.trades(for: acc, in: ctx), [])
    }

    func testDeletingTheAccountRemovesItsImportedTrades() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash, heldUnits: [a: 18, b: 5], into: acc, in: ctx)

        ctx.delete(acc)
        try ctx.save()

        XCTAssertEqual(try saved(ctx).count, 0)
    }

    // MARK: - Real amounts

    func testACashBuyIsSavedWithItsRealDebitAndKeyedByItsEstimate() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        let summary = try T.importOrders(ordersCSV: csv("20/01/2030;\(a);250.00 EUR;25,000;Finalizada"),
                                         movementsCSV: cash([("22/01/2030", "-250,03")]),
                                         heldUnits: [a: 25], into: acc, in: ctx)

        let trade = try saved(ctx, key: "myinvestor:v1:2030-01-20:\(a):25:250#1")
        XCTAssertEqual(trade.amountEur, d("250.03"))
        XCTAssertEqual(summary.matchedToCash, 1)
        XCTAssertEqual(summary.amountsCorrected, 0)
        XCTAssertEqual(summary.positions.map(\.costEur), [d("250.03")])
    }

    func testACashSaleIsSavedWithTheCreditReceivedAfterWithholding() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // The estimate says 1500; tax withheld on the gain leaves 1475.50.
        try T.importOrders(ordersCSV: csv(
            "20/03/2030;\(a);1500.00 EUR;100,000;Finalizada",
            "20/01/2030;\(a);1000.00 EUR;100,000;Finalizada"
        ), movementsCSV: cash([("24/03/2030", "1.475,50"), ("21/01/2030", "-1.000")]),
        heldUnits: [:], into: acc, in: ctx)

        XCTAssertEqual(try saved(ctx, key: "myinvestor:v1:2030-03-20:\(a):100:1500#1").amountEur, d("1475.5"))
        XCTAssertEqual(F.positions(try T.trades(for: acc, in: ctx)).map(\.realisedGainEur), [d("475.5")])
    }

    private var gainSale: String { "myinvestor:v1:2030-03-10:\(a):100:1000#1" }

    func testASaleWithAGainMatchesACreditShortByTheTaxWithheld() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // a bought for 600 and sold at an estimate of 1000: up to 19% of the 400 gain can be
        // withheld, so with the usual 2% the credit can be as low as 904. b's buy falls between
        // a's orders. The transfer is the estimate to the cent and a day closer, but never a fund order.
        let summary = try T.importOrders(
            ordersCSV: csv("10/03/2030;\(a);1000.00 EUR;100,000;Finalizada",
                           "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
                           "20/01/2030;\(a);600.00 EUR;100,000;Finalizada"),
            movementsCSV: cash([("13/03/2030", "930"), ("16/02/2030", "-50"), ("21/01/2030", "-600")],
                               other: ["11/03/2030;11/03/2030;TRANSFER MYINVESTOR;1.000;EUR"]),
            heldUnits: [b: 5], into: acc, in: ctx)

        XCTAssertEqual(summary.matchedToCash, 3)
        XCTAssertEqual(try saved(ctx, key: gainSale).amountEur, 930)
        XCTAssertEqual(summary.positions.map(\.realisedGainEur), [330, 0])
    }

    func testTheSameShortCreditWithoutAGainIsRefused() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // Bought for 1000: nothing to withhold, so 930 is 7% short of the estimate.
        let error = importError {
            try T.importOrders(ordersCSV: csv("10/03/2030;\(a);1000.00 EUR;100,000;Finalizada",
                                              "20/01/2030;\(a);1000.00 EUR;100,000;Finalizada"),
                               movementsCSV: cash([("13/03/2030", "930"), ("21/01/2030", "-1.000")]),
                               heldUnits: [:], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unmatchedOrders([gainSale]))
        XCTAssertEqual(try saved(ctx).count, 0)
    }

    func testANonFundMovementIsNeverMatched() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // A transfer in for exactly the sale's estimate, the day after it.
        let error = importError {
            try T.importOrders(ordersCSV: csv(
                "10/03/2030;\(a);1000.00 EUR;100,000;Finalizada",
                "20/01/2030;\(a);900.00 EUR;100,000;Finalizada"
            ), movementsCSV: cash([("21/01/2030", "-900")], other: ["11/03/2030;11/03/2030;TRANSFER MYINVESTOR;1.000;EUR"]),
            heldUnits: [:], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unmatchedOrders(["myinvestor:v1:2030-03-10:\(a):100:1000#1"]))
    }

    func testAnOrderWithNeitherCashNorASwitchPartnerIsRefusedAndNothingIsWritten() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: csv("20/01/2030;\(a);100.00 EUR;10,000;Finalizada"),
                           movementsCSV: cash([("21/01/2030", "-100")]), heldUnits: [a: 10], into: acc, in: ctx)
        let before = try saved(ctx).map { [$0.id.uuidString, "\($0.amountEur)"] }

        // b's debit is missing, and the first buy's is now a cent off: a correction that must not land.
        let error = importError {
            try T.importOrders(ordersCSV: csv(
                "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
                "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
            ), movementsCSV: cash([("21/01/2030", "-100,01")]), heldUnits: [a: 10, b: 5], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unmatchedOrders(["myinvestor:v1:2030-02-15:\(b):5:50#1"]))
        XCTAssertEqual(try saved(ctx).map { [$0.id.uuidString, "\($0.amountEur)"] }, before)
        XCTAssertFalse(ctx.hasChanges)
    }

    func testReimportingWithTheCashExportCorrectsAmountsSavedFromEstimates() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let earlier = utcDay(2030, 3, 20)
        // As an import without the cash export saved them: estimates, the switch already grouped.
        let group = UUID()
        let rows: [(String, String, Date, FundTradeSide, Decimal, Decimal, UUID?)] = [
            ("myinvestor:v1:2030-01-20:\(a):100:1000#1", a, utcDay(2030, 1, 20), .buy, 100, 1000, nil),
            ("myinvestor:v1:2030-03-10:\(a):100:1200#1", a, utcDay(2030, 3, 10), .sell, 100, 1200, group),
            ("myinvestor:v1:2030-03-12:\(b):60:1190#1", b, utcDay(2030, 3, 12), .buy, 60, 1190, group),
            ("myinvestor:v1:2030-03-15:\(c):30:300#1", c, utcDay(2030, 3, 15), .buy, 30, 300, nil),
        ]
        for (key, isin, date, side, units, amount, switchGroup) in rows {
            ctx.insert(FundTrade(account: acc, isin: isin, tradeDate: date, side: side, units: units, amountEur: amount,
                                 switchGroupId: switchGroup, importKey: key, createdAt: earlier, updatedAt: earlier))
        }
        try ctx.save()
        let orders = csv("15/03/2030;\(c);300.00 EUR;30,000;Finalizada",
                         "12/03/2030;\(b);1190.00 EUR;60,000;Finalizada",
                         "10/03/2030;\(a);1200.00 EUR;100,000;Finalizada",
                         "20/01/2030;\(a);1000.00 EUR;100,000;Finalizada")
        let movements = cash([("17/03/2030", "-299,90"), ("21/01/2030", "-1.000,25")])
        let now = utcDay(2030, 4, 1)

        let summary = try T.importOrders(ordersCSV: orders, movementsCSV: movements,
                                         heldUnits: [b: 60, c: 30], into: acc, in: ctx, now: now)

        XCTAssertEqual(summary.inserted, 0)
        XCTAssertEqual(summary.matchedToCash, 2)
        XCTAssertEqual(summary.switchPairs, 1)
        XCTAssertEqual(summary.switchPairsAdded, 0)
        // +0.25 and -0.10 from the debits, -10 for the sale that reached b as 1190.
        XCTAssertEqual(summary.amountsCorrected, 3)
        XCTAssertEqual(summary.amountsCorrectedEur, d("-9.85"))
        XCTAssertEqual(try saved(ctx).map(\.amountEur), [d("1000.25"), 1190, 1190, d("299.9")])
        XCTAssertEqual(try saved(ctx).map(\.updatedAt), [now, now, earlier, now])
        XCTAssertEqual(try saved(ctx).map(\.switchGroupId), [nil, group, group, nil])

        let again = try T.importOrders(ordersCSV: orders, movementsCSV: movements,
                                       heldUnits: [b: 60, c: 30], into: acc, in: ctx, now: utcDay(2030, 4, 2))

        XCTAssertEqual(again.amountsCorrected, 0)
        XCTAssertEqual(again.amountsCorrectedEur, 0)
        XCTAssertEqual(again.alreadyPresent, 4)
        XCTAssertEqual(try saved(ctx).map(\.updatedAt), [now, now, earlier, now])
        XCTAssertFalse(ctx.hasChanges)
    }

    // MARK: - Switches

    // a bought, then sold and switched into b two days later for 5 less. Only the first buy
    // moved cash.
    private var switchOrders: [String] {
        ["12/03/2030;\(b);1195.00 EUR;60,000;Finalizada",
         "10/03/2030;\(a);1200.00 EUR;100,000;Finalizada",
         "20/01/2030;\(a);1000.00 EUR;100,000;Finalizada"]
    }
    private var switchCash: String { cash([("21/01/2030", "-1.000")]) }
    private var switchSell: String { "myinvestor:v1:2030-03-10:\(a):100:1200#1" }
    private var switchBuy: String { "myinvestor:v1:2030-03-12:\(b):60:1195#1" }

    func testSwitchLegsShareAGroupThatReimportingLeavesAlone() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let export = csv(switchOrders[0], switchOrders[1], switchOrders[2])

        let first = try T.importOrders(ordersCSV: export, movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)

        XCTAssertEqual(first.matchedToCash, 1)
        XCTAssertEqual(first.switchPairs, 1)
        XCTAssertEqual(first.switchPairsAdded, 1)
        let group = try XCTUnwrap(try saved(ctx, key: switchSell).switchGroupId)
        XCTAssertEqual(try saved(ctx, key: switchBuy).switchGroupId, group)
        XCTAssertNil(try saved(ctx, key: "myinvestor:v1:2030-01-20:\(a):100:1000#1").switchGroupId)
        // The sale is worth what reached b.
        XCTAssertEqual(try saved(ctx, key: switchSell).amountEur, 1195)

        let again = try T.importOrders(ordersCSV: export, movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)

        XCTAssertEqual(again.switchPairs, 1)
        XCTAssertEqual(again.switchPairsAdded, 0)
        XCTAssertEqual(try saved(ctx, key: switchSell).switchGroupId, group)
        XCTAssertEqual(try saved(ctx, key: switchBuy).switchGroupId, group)
    }

    func testSwitchLegsUpToTwoPercentAndSixDaysApartPair() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        try T.importOrders(ordersCSV: csv(
            "16/03/2030;\(b);985.00 EUR;50,000;Finalizada",
            "10/03/2030;\(a);1000.00 EUR;100,000;Finalizada",
            "20/01/2030;\(a);900.00 EUR;100,000;Finalizada"
        ), movementsCSV: cash([("21/01/2030", "-900")]), heldUnits: [b: 50], into: acc, in: ctx)

        let sell = try saved(ctx, key: "myinvestor:v1:2030-03-10:\(a):100:1000#1")
        let buy = try saved(ctx, key: "myinvestor:v1:2030-03-16:\(b):50:985#1")
        XCTAssertEqual(sell.amountEur, 985)
        XCTAssertEqual(buy.amountEur, 985)
        XCTAssertNotNil(sell.switchGroupId)
        XCTAssertEqual(sell.switchGroupId, buy.switchGroupId)
        XCTAssertEqual(F.positions(try T.trades(for: acc, in: ctx)).map(\.realisedGainEur), [85, 0])
    }

    func testSwitchesChainedThroughAFundEachSaveTheirSaleAtTheBuysAmount() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // a is switched into b, and b into c a week later. Only a's first buy moved cash.
        let summary = try T.importOrders(ordersCSV: csv(
            "17/03/2030;\(c);6000.10 EUR;50,000;Finalizada",
            "17/03/2030;\(b);6001.25 EUR;60,000;Finalizada",
            "11/03/2030;\(b);6001.20 EUR;60,000;Finalizada",
            "10/03/2030;\(a);6000.00 EUR;100,000;Finalizada",
            "20/01/2030;\(a);5800.00 EUR;100,000;Finalizada"
        ), movementsCSV: cash([("21/01/2030", "-5.800")]), heldUnits: [c: 50], into: acc, in: ctx)

        XCTAssertEqual(summary.matchedToCash, 1)
        XCTAssertEqual(summary.switchPairs, 2)
        XCTAssertEqual(summary.switchPairsAdded, 2)
        let sellA = try saved(ctx, key: "myinvestor:v1:2030-03-10:\(a):100:6000#1")
        let buyB = try saved(ctx, key: "myinvestor:v1:2030-03-11:\(b):60:6001.2#1")
        let sellB = try saved(ctx, key: "myinvestor:v1:2030-03-17:\(b):60:6001.25#1")
        let buyC = try saved(ctx, key: "myinvestor:v1:2030-03-17:\(c):50:6000.1#1")
        XCTAssertEqual(sellA.amountEur, d("6001.2"))
        XCTAssertEqual(sellB.amountEur, d("6000.1"))
        XCTAssertNotNil(sellA.switchGroupId)
        XCTAssertEqual(buyB.switchGroupId, sellA.switchGroupId)
        XCTAssertNotNil(sellB.switchGroupId)
        XCTAssertEqual(buyC.switchGroupId, sellB.switchGroupId)
        XCTAssertNotEqual(sellA.switchGroupId, sellB.switchGroupId)
        XCTAssertEqual(summary.positions, [
            F.Position(isin: a, units: 0, costEur: 0, realisedGainEur: d("201.2"), priceEur: nil),
            F.Position(isin: b, units: 0, costEur: 0, realisedGainEur: d("-1.1"), priceEur: nil),
            F.Position(isin: c, units: 50, costEur: d("6000.1"), realisedGainEur: 0, priceEur: nil),
        ])
    }

    func testASwitchWhoseBuyIsStillInProgressIsRefusedUntilItSettles() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        let error = importError {
            try T.importOrders(ordersCSV: csv("12/03/2030;\(b);1195 EUR;;En curso", switchOrders[1], switchOrders[2]),
                               movementsCSV: switchCash, heldUnits: [:], into: acc, in: ctx)
        }
        XCTAssertEqual(error, .unmatchedOrders([switchSell]))
        XCTAssertEqual(try saved(ctx).count, 0)

        let summary = try T.importOrders(ordersCSV: csv(switchOrders[0], switchOrders[1], switchOrders[2]),
                                         movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)

        XCTAssertEqual(summary.switchPairsAdded, 1)
        let group = try XCTUnwrap(try saved(ctx, key: switchSell).switchGroupId)
        XCTAssertEqual(try saved(ctx, key: switchBuy).switchGroupId, group)
    }

    func testAnOrderInProgressKeepsTheDebitTakenForItFromADoneSwitchBuy() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        // a is switched into b on the 12th. c's buy two days later is still in progress, but the
        // broker has taken its debit, which is also within reach of b's buy.
        let summary = try T.importOrders(ordersCSV: csv(
            "14/03/2030;\(c);500.00 EUR;;En curso",
            "12/03/2030;\(b);500.00 EUR;40,000;Finalizada",
            "10/03/2030;\(a);500.00 EUR;50,000;Finalizada",
            "20/01/2030;\(a);450.00 EUR;50,000;Finalizada"
        ), movementsCSV: cash([("14/03/2030", "-500"), ("21/01/2030", "-450")]), heldUnits: [b: 40], into: acc, in: ctx)

        XCTAssertEqual(summary.matchedToCash, 1)
        XCTAssertEqual(summary.switchPairsAdded, 1)
        XCTAssertEqual(summary.skippedInProgress, 1)
        XCTAssertEqual(try saved(ctx).map(\.isin), [a, a, b])
        let sell = try saved(ctx, key: "myinvestor:v1:2030-03-10:\(a):50:500#1")
        XCTAssertNotNil(sell.switchGroupId)
        XCTAssertEqual(try saved(ctx, key: "myinvestor:v1:2030-03-12:\(b):40:500#1").switchGroupId, sell.switchGroupId)
    }

    func testASavedSwitchKeepsItsLegsWhenACloserBuyArrives() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let export = csv(switchOrders[0], switchOrders[1], switchOrders[2])
        try T.importOrders(ordersCSV: export, movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)
        let group = try XCTUnwrap(try saved(ctx, key: switchSell).switchGroupId)

        // Same day and amount as the sale, and no cash: a better match than b, but the sale is
        // taken, so it is the new buy that has no partner.
        let error = importError {
            try T.importOrders(
                ordersCSV: csv("10/03/2030;\(c);1200.00 EUR;50,000;Finalizada", switchOrders[0], switchOrders[1], switchOrders[2]),
                movementsCSV: switchCash, heldUnits: [b: 60, c: 50], into: acc, in: ctx)
        }

        XCTAssertEqual(error, .unmatchedOrders(["myinvestor:v1:2030-03-10:\(c):50:1200#1"]))
        XCTAssertEqual(try saved(ctx, key: switchSell).switchGroupId, group)
        XCTAssertEqual(try saved(ctx, key: switchBuy).switchGroupId, group)
    }

    func testALegWhosePartnerIsGoneLendsItsGroupToTheNewPartner() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let export = csv(switchOrders[0], switchOrders[1], switchOrders[2])
        try T.importOrders(ordersCSV: export, movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)
        let group = try XCTUnwrap(try saved(ctx, key: switchSell).switchGroupId)
        // The buy was deleted, say.
        ctx.delete(try saved(ctx, key: switchBuy))
        try ctx.save()

        let summary = try T.importOrders(ordersCSV: export, movementsCSV: switchCash, heldUnits: [b: 60], into: acc, in: ctx)

        XCTAssertEqual(summary.inserted, 1)
        XCTAssertEqual(summary.switchPairsAdded, 1)
        XCTAssertEqual(try saved(ctx, key: switchSell).switchGroupId, group)
        XCTAssertEqual(try saved(ctx, key: switchBuy).switchGroupId, group)
    }

    // MARK: - Held units guess

    func testEveryFundInTheExportIsListedAndOnlySavedOnesAreGuessed() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        try T.importOrders(ordersCSV: firstExport, movementsCSV: firstCash, heldUnits: [a: 18, b: 5], into: acc, in: ctx)

        let guesses = try T.guessHeldUnits(ordersCSV: csv(
            "15/04/2030;\(c);30.00 EUR;;Cancelada",
            "12/04/2030;\(b);20.00 EUR;;En curso",
            "10/04/2030;\(a);60.00 EUR;6,000;Finalizada",
            "20/03/2030;\(a);125.00 EUR;12,000;Finalizada",
            "20/02/2030;\(a);205.00 EUR;20,000;Finalizada",
            "15/02/2030;\(b);50.00 EUR;5,000;Finalizada",
            // Identical to a saved order, so it's numbered as a second one and is new.
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada",
            "20/01/2030;\(a);100.00 EUR;10,000;Finalizada"
        ), for: acc, in: ctx)

        // a: 18 saved, plus 6 and 10 new read as buys. b: its only new order isn't done.
        XCTAssertEqual(guesses, [
            T.HeldUnitsGuess(isin: a, units: 34),
            T.HeldUnitsGuess(isin: b, units: 5),
            T.HeldUnitsGuess(isin: c, units: nil),
        ])
    }

    func testAFundSoldOutWithNothingNewIsGuessedAtZero() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let orders = csv("20/02/2030;\(a);110.00 EUR;10,000;Finalizada",
                         "20/01/2030;\(a);100.00 EUR;10,000;Finalizada")
        try T.importOrders(ordersCSV: orders, movementsCSV: cash([("21/02/2030", "110"), ("21/01/2030", "-100")]),
                           heldUnits: [:], into: acc, in: ctx)

        XCTAssertEqual(try T.guessHeldUnits(ordersCSV: orders, for: acc, in: ctx), [T.HeldUnitsGuess(isin: a, units: 0)])
    }

    func testAGuessFromAFileThatIsntTheOrdersExportThrowsItsParseError() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        XCTAssertThrowsError(try T.guessHeldUnits(ordersCSV: cashHeader, for: acc, in: ctx)) { error in
            XCTAssertEqual(error as? CoreLogic.MyInvestorOrdersCSV.ParseError,
                           .unknownHeader(CoreLogic.MyInvestorMovementsCSV.columns))
        }
    }

    // MARK: - Broker cash

    func testBrokerCashAnchorIsPinnedToTheUTCDayAndClearedWithItsAmount() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)

        try T.setBrokerCashAnchor(acc, amountEur: 500, at: utcDay(2030, 3, 1).addingTimeInterval(15 * 3600), in: ctx)
        XCTAssertEqual(acc.brokerCashAnchorEur, 500)
        XCTAssertEqual(acc.brokerCashAnchorAt, utcDay(2030, 3, 1))

        try T.setBrokerCashAnchor(acc, amountEur: nil, at: utcDay(2030, 3, 1), in: ctx)
        XCTAssertNil(acc.brokerCashAnchorEur)
        XCTAssertNil(acc.brokerCashAnchorAt)
    }

    func testCashLedgerRunsTheAnchorThroughTheAccountsTransfersAndTrades() throws {
        let ctx = try S.makeContext()
        let acc = try makeInvestmentAccount(ctx)
        let other = S.makeAccount(ctx, name: "Elsewhere")
        _ = S.makeTx(ctx, account: acc, amount: 1500, direction: .credit,
                     bookedAt: utcDay(2030, 1, 15).addingTimeInterval(12 * 3600), isTransfer: true)
        _ = S.makeTx(ctx, account: other, amount: 900, direction: .credit,
                     bookedAt: utcDay(2030, 1, 16), isTransfer: true)
        try ctx.save()
        try T.importOrders(ordersCSV: csv(switchOrders[1], switchOrders[2]),
                           movementsCSV: cash([("11/03/2030", "1.200"), ("21/01/2030", "-1.000")]),
                           heldUnits: [:], into: acc, in: ctx)

        XCTAssertNil(try T.cashLedger(for: acc, in: ctx), "no anchor yet")

        try T.setBrokerCashAnchor(acc, amountEur: 0, at: utcDay(2030, 1, 1), in: ctx)
        let ledger = try XCTUnwrap(try T.cashLedger(for: acc, in: ctx))

        XCTAssertEqual(ledger.days, [
            F.CashDay(date: utcDay(2030, 1, 1), cashEur: 0),
            F.CashDay(date: utcDay(2030, 1, 15), cashEur: 1500),
            F.CashDay(date: utcDay(2030, 1, 20), cashEur: 500),
            F.CashDay(date: utcDay(2030, 3, 10), cashEur: 1700),
        ])
    }
}
