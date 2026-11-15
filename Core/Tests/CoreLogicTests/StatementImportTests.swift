import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class StatementImportTests: XCTestCase {
    typealias S = TransferTestSupport

    private let csv = """
    Type,Started Date,Completed Date,Description,Amount,Fee,Balance
    CARD_PAYMENT,2026-08-01 01:10:00,2026-08-02 10:00:00,Olivo,-14.00,0.00,-100.00
    CARD_PAYMENT,2026-08-04 00:40:00,2026-08-05 10:30:00,Olivo,-14.00,0.00,-116.00
    CARD_PAYMENT,2026-08-12 15:00:00,2026-08-14 10:00:00,Google One,-4.99,0.00,-120.99
    TRANSFER,2026-08-19 18:00:00,2026-08-19 18:00:00,To EUR,500.00,0.00,85.00
    """

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testMatchesNearestQuickAddAndInsertsTheRest() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let card = try CoreLogic.Accounts.createManual(
            name: "Credit Card", institution: "Revolut", currency: "EUR", space: space, in: ctx)
        let subs = CoreModel.Category(name: "Subscriptions", kind: "expense")
        ctx.insert(subs)
        _ = try CoreLogic.CategoryRules.create(pattern: "Google", category: subs, in: ctx)
        // Quick-added two hours before the 4 Aug statement time; the 1 Aug row is 3 days away
        // and must NOT steal it.
        let quick = try CoreLogic.Transactions.createManual(
            account: card, amount: 14, bookedAt: date("2026-08-03T22:40:59Z"),
            description: "Bar El Olivo", in: ctx)

        let summary = try CoreLogic.StatementImport.importCSV(csv, into: card, in: ctx)

        XCTAssertEqual(summary.parsed, 4)
        XCTAssertEqual(summary.skippedTransfers, 1)
        XCTAssertEqual(summary.matchedManual, 1)
        XCTAssertEqual(summary.inserted, 2)
        XCTAssertEqual(summary.categorized, 1)
        XCTAssertEqual(quick.externalId, "revolutcsv:v1:2026-08-03:-14.00:olivo:0")
        XCTAssertEqual(quick.transactionDescription, "Bar El Olivo")
        XCTAssertEqual(quick.valueAt, date("2026-08-05T08:30:00Z"))
        XCTAssertEqual(quick.bookedAt, date("2026-08-03T22:40:00Z"))

        let all = try ctx.fetch(FetchDescriptor<Transaction>()).sorted { $0.bookedAt < $1.bookedAt }
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].externalId, "revolutcsv:v1:2026-07-31:-14.00:olivo:0")
        XCTAssertEqual(all[0].direction, .debit)
        XCTAssertEqual(all[0].amountEur, -14)
        XCTAssertEqual(all[2].category?.id, subs.id)

        // Re-import is a no-op.
        let again = try CoreLogic.StatementImport.importCSV(csv, into: card, in: ctx)
        XCTAssertEqual(again.skippedDuplicate, 3)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.matchedManual, 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>()), 3)
    }

    func testRefusesSyncedAccounts() throws {
        let ctx = try S.makeContext()
        let conn = Connection(connector: .enablebanking, institutionId: "x", institutionName: "X")
        ctx.insert(conn)
        let bank = S.makeAccount(ctx, name: "Bank", connection: conn)
        XCTAssertThrowsError(try CoreLogic.StatementImport.importCSV(csv, into: bank, in: ctx)) {
            XCTAssertEqual($0 as? CoreLogic.StatementImport.ImportError, .notManualAccount)
        }
    }

    func testRecurringMatchesWiderAndUnclaimedQuickAddsSurface() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let card = try CoreLogic.Accounts.createManual(
            name: "Credit Card", institution: "Revolut", currency: "EUR", space: space, in: ctx)
        // Booked on the expected day; the real charge landed 5 days later.
        let auto = try CoreLogic.Transactions.createManual(
            account: card, amount: Decimal(string: "4.99")!, bookedAt: date("2026-08-07T10:00:00Z"), in: ctx)
        auto.externalId = CoreLogic.Automations.recurringPrefix + "2026-08:google-one"
        let ghost = try CoreLogic.Transactions.createManual(
            account: card, amount: 20, bookedAt: date("2026-08-05T10:00:00Z"), description: "Tipless", in: ctx)
        _ = try CoreLogic.Transactions.createManual(
            account: card, amount: 7, bookedAt: date("2026-08-20T10:00:00Z"), in: ctx)

        let summary = try CoreLogic.StatementImport.importCSV(csv, into: card, in: ctx)

        XCTAssertTrue(auto.externalId.hasPrefix("revolutcsv:v1:2026-08-12:-4.99"))
        XCTAssertEqual(summary.unmatched.map(\.id), [ghost.id])
        try CoreLogic.StatementImport.deleteUnmatched(ids: summary.unmatched.map(\.id), in: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>()), 4)
    }

    func testAmexKeepsTapTimeInsertsCreditsAndSkipsRoutedPayment() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let card = try CoreLogic.Accounts.createManual(
            name: "Charge Card", institution: "American Express", currency: "EUR", space: space, in: ctx)
        let tap = date("2026-03-14T19:45:00Z")
        let quick = try CoreLogic.Transactions.createManual(
            account: card, amount: Decimal(string: "12.50")!, bookedAt: tap, description: "Grocer", in: ctx)
        // The paying bank's transfer route already mirrored the card payment onto the card.
        _ = S.makeTx(ctx, account: card, amount: 300, direction: .credit, bookedAt: date("2026-03-20T08:00:00Z"),
                     externalId: CoreLogic.TransferRoutes.mirrorExternalId(UUID()))
        try ctx.save()
        let csv = """
        Fecha,Descripción,Importe,Aparece en su Estado de Cuenta como,Referencia,Categoría
        14/03/2026,SAMPLE GROCER,"12,50",SAMPLE GROCER,'REF1',Productos-Comestibles
        15/03/2026,EXAMPLE STORE,"40,00",EXAMPLE STORE,'REF2',Productos-Otros Productos
        16/03/2026,EXAMPLE STORE,"-10,00",EXAMPLE STORE,'REF3',Productos-Otros Productos
        21/03/2026,PAYMENT,"-300,00",PAYMENT,'REF4',
        """

        let summary = try CoreLogic.StatementImport.importCSV(csv, into: card, in: ctx)

        XCTAssertEqual(summary.parsed, 4)
        XCTAssertEqual(summary.matchedManual, 1)
        XCTAssertEqual(summary.inserted, 2)
        XCTAssertEqual(summary.skippedTransfers, 1)
        XCTAssertEqual(quick.externalId, "amex:v1:REF1")
        XCTAssertEqual(quick.bookedAt, tap)
        XCTAssertNil(quick.valueAt)
        XCTAssertEqual(quick.transactionDescription, "Grocer")
        let refund = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Transaction>()).first { $0.externalId == "amex:v1:REF3" })
        XCTAssertEqual(refund.direction, .credit)
        XCTAssertEqual(refund.amountEur, 10)
        // The payment counts once, through the mirror.
        XCTAssertEqual(CoreLogic.Accounts.computeNativeBalances([card], in: ctx)[card.id], Decimal(string: "257.50"))

        let again = try CoreLogic.StatementImport.importCSV(csv, into: card, in: ctx)
        XCTAssertEqual(again.skippedDuplicate, 3)
        XCTAssertEqual(again.skippedTransfers, 1)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.matchedManual, 0)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Transaction>()), 4)
    }
}
