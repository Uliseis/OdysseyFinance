import XCTest
import SwiftData
@testable import CoreLogic
@testable import CoreModel

@MainActor
final class AccountsMutationsTests: XCTestCase {
    typealias S = TransferTestSupport
    typealias A = CoreLogic.Accounts

    func testCreateManualSetsExternalIdPrefixAndOpeningBalance() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let a = try A.createManual(
            name: "  Cash  ", institution: "  Wallet  ", currency: "eur",
            space: space, openingBalance: 250, in: ctx)
        XCTAssertTrue(a.externalId.hasPrefix("manual:"))
        XCTAssertEqual(a.name, "Cash")
        XCTAssertEqual(a.institution, "Wallet")
        XCTAssertEqual(a.currency, "EUR")
        XCTAssertNil(a.connection)
        XCTAssertEqual(a.balance, 250)
        XCTAssertEqual(a.manualOpeningBalance, 250)
        XCTAssertNotNil(a.balanceUpdatedAt)
    }

    func testAddInterestInsertsPositiveCredit() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let a = try A.createManual(
            name: "Savings", institution: "Revolut", currency: "EUR", space: space, in: ctx)
        let tx = try A.addInterest(a, amount: 12.34, at: .now, note: nil, in: ctx)
        XCTAssertTrue(tx.externalId.hasPrefix("manual-interest:"))
        XCTAssertEqual(tx.direction, .credit)
        XCTAssertEqual(tx.amount, 12.34)
        XCTAssertEqual(tx.amountEur, 12.34)
        XCTAssertEqual(tx.transactionDescription, "Interest")
        XCTAssertEqual(tx.counterparty, "Revolut")
        XCTAssertEqual(tx.account?.id, a.id)
    }

    func testAddInterestUsesTrimmedNoteAndRejectsNonPositive() throws {
        let ctx = try S.makeContext()
        let a = try A.createManual(name: "Savings", institution: "Revolut", in: ctx)
        let tx = try A.addInterest(a, amount: 5, at: .now, note: "  Q2 interest ", in: ctx)
        XCTAssertEqual(tx.transactionDescription, "Q2 interest")
        XCTAssertThrowsError(try A.addInterest(a, amount: 0, at: .now, in: ctx)) {
            XCTAssertEqual($0 as? A.MutationError, .amountMustBePositive)
        }
    }

    func testCreateManualDefaultsToDefaultSpace() throws {
        let ctx = try S.makeContext()
        let a = try A.createManual(name: "Cash", institution: "Wallet", in: ctx)
        XCTAssertEqual(a.space?.name, "Individual")
        XCTAssertEqual(a.space?.isDefault, true)
        XCTAssertNil(a.balanceUpdatedAt) // no opening balance
    }

    func testCreateManualRejectsBlankNameInstitutionCurrency() throws {
        let ctx = try S.makeContext()
        XCTAssertThrowsError(try A.createManual(name: " ", institution: "X", in: ctx)) {
            XCTAssertEqual($0 as? A.MutationError, .nameRequired)
        }
        XCTAssertThrowsError(try A.createManual(name: "X", institution: " ", in: ctx)) {
            XCTAssertEqual($0 as? A.MutationError, .institutionRequired)
        }
        XCTAssertThrowsError(try A.createManual(name: "X", institution: "Y", currency: "EU", in: ctx)) {
            XCTAssertEqual($0 as? A.MutationError, .invalidCurrency)
        }
    }

    func testUpdateChangesFieldsAndMarksCurrencyOverride() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let group = try CoreLogic.AccountGroups.create(name: "Cash", in: ctx)
        let a = try A.createManual(name: "Old", institution: "Bank", space: space, in: ctx)
        let repair = try A.update(
            a, name: "New", type: .broker, institution: "Broker", currency: "usd",
            group: group, space: space, excluded: true, openingBalance: 99, in: ctx)
        XCTAssertNil(repair) // space unchanged ⇒ no repair
        XCTAssertEqual(a.name, "New")
        XCTAssertEqual(a.type, .broker)
        XCTAssertEqual(a.currency, "USD")
        XCTAssertEqual(a.group?.id, group.id)
        XCTAssertTrue(a.excluded)
        XCTAssertEqual(a.manualOpeningBalance, 99)
        let meta = try XCTUnwrap(a.metadataJSON
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(meta["currencyOverride"] as? Bool, true)
        XCTAssertNotNil(meta["currencyOverrideAt"])
    }

    func testUpdateSpaceChangeRepairsCrossSpaceGroup() throws {
        let ctx = try S.makeContext()
        let space1 = S.makeSpace(ctx, name: "One")
        let space2 = AccountSpace(name: "Two")
        ctx.insert(space2)
        let accA = S.makeAccount(ctx, name: "A", space: space1)
        let accB = S.makeAccount(ctx, name: "B", space: space1)
        let group = TransferGroup()
        ctx.insert(group)
        let txA = S.makeTx(ctx, account: accA, amount: -100, direction: .debit,
                           isTransfer: true, transferGroup: group)
        _ = S.makeTx(ctx, account: accB, amount: 100, direction: .credit,
                     isTransfer: true, transferGroup: group)
        try ctx.save()

        let repair = try A.update(
            accA, name: accA.name, type: accA.type, institution: accA.institution,
            currency: accA.currency, group: nil, space: space2,
            excluded: false, openingBalance: nil, in: ctx)
        XCTAssertEqual(repair?.groupsBroken, 1)
        XCTAssertNil(txA.transferGroup)
        XCTAssertFalse(txA.isTransfer)
    }

    func testUpdateDoesNotClobberConnectedAccountBalance() throws {
        let ctx = try S.makeContext()
        let conn = Connection(connector: .enablebanking)
        ctx.insert(conn)
        let a = S.makeAccount(ctx, name: "Bank", connection: conn)
        a.balance = 1234
        try ctx.save()
        _ = try A.update(
            a, name: "Bank2", type: a.type, institution: a.institution,
            currency: a.currency, group: nil, space: a.space,
            excluded: false, openingBalance: 0, in: ctx)
        XCTAssertEqual(a.balance, 1234) // untouched
        XCTAssertNil(a.manualOpeningBalance)
    }

    func testSetArchivedTriggersRepairAndNoOpsWhenUnchanged() throws {
        let ctx = try S.makeContext()
        let a = try A.createManual(name: "Cash", institution: "Wallet", in: ctx)
        XCTAssertNil(try A.setArchived(a, false, in: ctx)) // already false
        let repair = try A.setArchived(a, true, in: ctx)
        XCTAssertNotNil(repair)
        XCTAssertTrue(a.archived)
    }

    // MARK: - archiveImpact

    private func pair(_ ctx: ModelContext, _ from: Account, _ to: Account, _ amount: Decimal) {
        let group = TransferGroup(pairedAt: .now)
        ctx.insert(group)
        _ = S.makeTx(ctx, account: from, amount: -amount, direction: .debit, isTransfer: true, transferGroup: group)
        _ = S.makeTx(ctx, account: to, amount: amount, direction: .credit, isTransfer: true, transferGroup: group)
    }

    func testArchiveImpactCountsPairsWithActiveAccounts() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let holding = S.makeAccount(ctx, name: "Holding", space: space)
        let invest = S.makeAccount(ctx, name: "Invest", space: space, excluded: true)
        let bank = S.makeAccount(ctx, name: "Bank", space: space)
        pair(ctx, holding, invest, 100)
        pair(ctx, holding, invest, 250)
        pair(ctx, bank, holding, 40)
        pair(ctx, bank, invest, 70) // doesn't touch the account being archived
        _ = S.makeTx(ctx, account: holding, amount: -5, direction: .debit)
        try ctx.save()

        let impact = try A.archiveImpact(of: holding, in: ctx)
        XCTAssertEqual(impact.transfers, 3)
        XCTAssertEqual(impact.copiesDeleted, 0)
        XCTAssertEqual(impact.counterparts, ["Bank", "Invest"])
        XCTAssertEqual(impact.totalEur, 390)
        XCTAssertEqual(impact.summary,
                       "Its 3 transfers with Bank and Invest are unpaired and count as income or spending again.")
        XCTAssertFalse(ctx.hasChanges, "the preview changes nothing")

        let repair = try XCTUnwrap(A.setArchived(holding, true, in: ctx))
        XCTAssertEqual(repair.groupsBroken, 3)
        let stillPaired = try ctx.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { $0.isTransfer }))
        XCTAssertEqual(stillPaired.count, 2, "only the bank ↔ invest pair is left")
    }

    func testArchiveImpactSkipsPairsWhoseOtherLegIsAlreadyArchived() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let holding = S.makeAccount(ctx, name: "Holding", space: space)
        let closed = S.makeAccount(ctx, name: "Closed", space: space, archived: true)
        pair(ctx, holding, closed, 60)
        try ctx.save()

        // Both legs end up on archived accounts, so nothing that counts changes.
        let impact = try A.archiveImpact(of: holding, in: ctx)
        XCTAssertTrue(impact.isEmpty)
        XCTAssertEqual(impact.counterparts, [])
        XCTAssertEqual(impact.totalEur, 0)
        XCTAssertEqual(try A.setArchived(holding, true, in: ctx)?.groupsBroken, 1)
    }

    func testArchiveImpactIsEmptyWithoutTransfersOrWhenAlreadyArchived() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let lone = S.makeAccount(ctx, name: "Lone", space: space)
        _ = S.makeTx(ctx, account: lone, amount: -5, direction: .debit)
        let gone = S.makeAccount(ctx, name: "Gone", space: space, archived: true)
        let other = S.makeAccount(ctx, name: "Other", space: space)
        pair(ctx, gone, other, 10) // a stale pair: archiving again changes nothing
        try ctx.save()

        XCTAssertTrue(try A.archiveImpact(of: lone, in: ctx).isEmpty)
        XCTAssertTrue(try A.archiveImpact(of: gone, in: ctx).isEmpty)
    }

    func testArchiveImpactSummaryForOneTransfer() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let holding = S.makeAccount(ctx, name: "Holding", space: space)
        let bank = S.makeAccount(ctx, name: "Bank", space: space)
        pair(ctx, bank, holding, 12.5)
        try ctx.save()

        let impact = try A.archiveImpact(of: holding, in: ctx)
        XCTAssertEqual(impact.transfers, 1)
        XCTAssertEqual(impact.totalEur, 12.5)
        XCTAssertEqual(impact.summary, "Its transfer with Bank is unpaired and counts as income or spending again.")
    }

    // A route mirror's group breaks like any pair; on top, the mirror row itself is deleted.
    func testArchiveImpactDescribesRouteMirrorsOnEitherSide() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let bank = S.makeAccount(ctx, name: "Bank", space: space)
        let card = S.makeAccount(ctx, name: "Card", space: space)
        let savings = S.makeAccount(ctx, name: "Savings", space: space)
        try CoreLogic.TransferRoutes.createRoute(pattern: "CARD PAYOFF", target: card, in: ctx)
        _ = S.makeTx(ctx, account: bank, amount: -50, direction: .debit,
                     bookedAt: .now.addingTimeInterval(-100 * 86_400), description: "CARD PAYOFF")
        pair(ctx, bank, savings, 30)
        try ctx.save()
        _ = try CoreLogic.TransferRoutes.apply(in: ctx)

        // The card holds the mirror: archiving it deletes the mirror, and the bank's row
        // counts as spending again.
        let fromCard = try A.archiveImpact(of: card, in: ctx)
        XCTAssertEqual(fromCard.transfers, 1)
        XCTAssertEqual(fromCard.copiesDeleted, 0)
        XCTAssertEqual(fromCard.counterparts, ["Bank"])
        XCTAssertEqual(fromCard.totalEur, 50)

        // The bank holds the source: archiving it deletes the mirror on the card.
        let fromBank = try A.archiveImpact(of: bank, in: ctx)
        XCTAssertEqual(fromBank.transfers, 2)
        XCTAssertEqual(fromBank.copiesDeleted, 1)
        XCTAssertEqual(fromBank.counterparts, ["Card", "Savings"])
        XCTAssertEqual(fromBank.totalEur, 80)
        XCTAssertEqual(fromBank.summary,
                       "Its 2 transfers with Card and Savings are unpaired: 1 counts as income or spending again, "
                       + "and 1 that a transfer route copied there is deleted.")

        let mirrors = FetchDescriptor<Transaction>(predicate: #Predicate { $0.routedFromTx != nil })
        let repair = try XCTUnwrap(A.setArchived(bank, true, in: ctx))
        XCTAssertEqual(repair.mirrorsDeleted, 1)
        XCTAssertEqual(try ctx.fetchCount(mirrors), 0)
    }

    func testArchiveImpactSummaryWhenEveryTransferIsACopy() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let bank = S.makeAccount(ctx, name: "Bank", space: space)
        let card = S.makeAccount(ctx, name: "Card", space: space)
        try CoreLogic.TransferRoutes.createRoute(pattern: "CARD PAYOFF", target: card, in: ctx)
        for amount: Decimal in [20, 35] {
            _ = S.makeTx(ctx, account: bank, amount: -amount, direction: .debit, description: "CARD PAYOFF")
        }
        try ctx.save()
        _ = try CoreLogic.TransferRoutes.apply(in: ctx)

        let impact = try A.archiveImpact(of: bank, in: ctx)
        XCTAssertEqual(impact.transfers, 2)
        XCTAssertEqual(impact.copiesDeleted, 2)
        XCTAssertEqual(impact.summary, "Its 2 transfers with Card were copied there by a transfer route and are deleted.")
    }

    func testSetAndClearAnchorTogether() throws {
        let ctx = try S.makeContext()
        let a = try A.createManual(name: "Cash", institution: "Wallet", in: ctx)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try A.setAnchor(a, balance: 500, at: when, in: ctx)
        XCTAssertEqual(a.balanceAnchor, 500)
        XCTAssertEqual(a.balanceAnchorAt, when)
        XCTAssertTrue(A.hasAnchor(a))
        try A.clearAnchor(a, in: ctx)
        XCTAssertNil(a.balanceAnchor)
        XCTAssertNil(a.balanceAnchorAt)
        XCTAssertFalse(A.hasAnchor(a))
    }

    func testAnchorDrivesComputedBalance() throws {
        let ctx = try S.makeContext()
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let anchorAt = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let a = try A.createManual(name: "Cash", institution: "Wallet", openingBalance: 0, in: ctx)
        _ = S.makeTx(ctx, account: a, amount: -10, amountEur: -10, direction: .debit,
                     bookedAt: cal.date(from: DateComponents(year: 2025, month: 12, day: 31))!)
        _ = S.makeTx(ctx, account: a, amount: 25, amountEur: 25, direction: .credit,
                     bookedAt: cal.date(from: DateComponents(year: 2026, month: 1, day: 2))!)
        try A.setAnchor(a, balance: 200, at: anchorAt, in: ctx)
        let native = A.computeNativeBalances([a], in: ctx)
        XCTAssertEqual(native[a.id], 225) // 200 anchor + 25 (tx after anchor); -10 before excluded
    }

    func testDeleteCascadesTransactions() throws {
        let ctx = try S.makeContext()
        let a = try A.createManual(name: "Cash", institution: "Wallet", in: ctx)
        _ = S.makeTx(ctx, account: a, amount: -10, direction: .debit)
        try ctx.save()
        try A.delete(a, in: ctx)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<Account>()).isEmpty)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<CoreModel.Transaction>()).isEmpty)
    }

    func testAliasOverridesDisplayNameAndBlankAliasClearsIt() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let a = try A.createManual(
            name: "JANE DOE EXAMPLE", institution: "Revolut",
            currency: "EUR", space: space, in: ctx)
        XCTAssertEqual(a.displayName, "JANE DOE EXAMPLE")

        _ = try A.update(a, name: a.name, alias: "  Revolut Daily  ", type: a.type,
                         institution: a.institution, currency: a.currency,
                         group: nil, space: space, excluded: false,
                         openingBalance: nil, in: ctx)
        XCTAssertEqual(a.alias, "Revolut Daily")
        XCTAssertEqual(a.displayName, "Revolut Daily")
        XCTAssertEqual(a.name, "JANE DOE EXAMPLE")

        // Whitespace-only alias clears rather than storing "" (which would blank the UI).
        _ = try A.update(a, name: a.name, alias: "   ", type: a.type,
                         institution: a.institution, currency: a.currency,
                         group: nil, space: space, excluded: false,
                         openingBalance: nil, in: ctx)
        XCTAssertNil(a.alias)
        XCTAssertEqual(a.displayName, "JANE DOE EXAMPLE")
    }

    func testUnarchiveRestoresRouteMirrorsAndRequestsFullSync() throws {
        let ctx = try S.makeContext()
        let space = S.makeSpace(ctx)
        let conn = Connection(connector: .enablebanking, status: .active)
        ctx.insert(conn)
        let bank = S.makeAccount(ctx, name: "Bank", space: space, connection: conn)
        let card = S.makeAccount(ctx, name: "Card", space: space)
        try CoreLogic.TransferRoutes.createRoute(pattern: "CARD PAYOFF", target: card, in: ctx)
        let source = S.makeTx(ctx, account: bank, amount: -50, direction: .debit,
                              bookedAt: .now.addingTimeInterval(-100 * 86_400), description: "CARD PAYOFF")
        try ctx.save()
        _ = try CoreLogic.TransferRoutes.apply(in: ctx)
        let sourceId = source.id
        let mirrors = FetchDescriptor<Transaction>(predicate: #Predicate { $0.routedFromTx?.id == sourceId })
        XCTAssertEqual(try ctx.fetchCount(mirrors), 1)

        try A.setArchived(card, true, in: ctx)
        XCTAssertEqual(try ctx.fetchCount(mirrors), 0)
        try A.setArchived(bank, true, in: ctx)
        try A.setArchived(card, false, in: ctx)
        try A.setArchived(bank, false, in: ctx)

        XCTAssertEqual(try ctx.fetchCount(mirrors), 1)
        XCTAssertTrue(source.isTransfer)
        let meta = try XCTUnwrap(bank.metadataJSON.flatMap {
            try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(meta["fullSyncRequested"] as? Bool, true)
        XCTAssertNil(card.metadataJSON)
    }
}
