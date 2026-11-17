import Foundation
import SwiftData
import CoreModel

extension CoreLogic.Accounts {
    public enum MutationError: Swift.Error, Equatable {
        case nameRequired
        case institutionRequired
        case invalidCurrency
        case amountMustBePositive
    }

    // Manual account: externalId is "manual:<uuid>", no connection. Opening balance seeds
    // both `balance` and `manualOpeningBalance` (web parity); the manual balance shape then
    // computes manualOpeningBalance + Σtx. Defaults to the default space when none given.
    @MainActor @discardableResult
    public static func createManual(
        name: String,
        type: AccountType = .bank,
        institution: String,
        currency: String = "EUR",
        group: AccountGroup? = nil,
        space: AccountSpace? = nil,
        openingBalance: Decimal? = nil,
        in ctx: ModelContext,
        now: Date = .now
    ) throws -> Account {
        let cleanName = try requireText(name, or: .nameRequired)
        let cleanInstitution = try requireText(institution, or: .institutionRequired)
        let cleanCurrency = try normalizedCurrency(currency)
        let resolvedSpace = try (space ?? CoreLogic.Spaces.ensureDefault(in: ctx, now: now))
        let account = Account(
            group: group,
            space: resolvedSpace,
            externalId: "manual:\(UUID().uuidString)",
            type: type,
            institution: cleanInstitution,
            name: cleanName,
            currency: cleanCurrency,
            balance: openingBalance,
            balanceUpdatedAt: openingBalance != nil ? now : nil,
            manualOpeningBalance: openingBalance,
            createdAt: now
        )
        ctx.insert(account)
        try ctx.saveTouchingChanges()
        return account
    }

    // Edits the user-controlled fields. Changing currency records the manual-override
    // marker so a future bank sync won't clobber it. Changing the space re-runs transfer
    // repair (cross-space groups break) — returns the repair result, or nil if unchanged.
    @MainActor @discardableResult
    public static func update(
        _ account: Account,
        name: String,
        alias: String? = nil,
        type: AccountType,
        institution: String,
        currency: String,
        group: AccountGroup?,
        space: AccountSpace?,
        excluded: Bool,
        openingBalance: Decimal?,
        in ctx: ModelContext,
        now: Date = .now
    ) throws -> CoreLogic.Transfers.RepairResult? {
        let cleanName = try requireText(name, or: .nameRequired)
        let cleanInstitution = try requireText(institution, or: .institutionRequired)
        let cleanCurrency = try normalizedCurrency(currency)

        let spaceChanged = account.space?.id != space?.id
        let currencyChanged = account.currency != cleanCurrency

        account.name = cleanName
        // Blank alias clears it rather than storing "" — displayName falls back to `name`.
        let cleanAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        account.alias = (cleanAlias?.isEmpty ?? true) ? nil : cleanAlias
        account.type = type
        account.institution = cleanInstitution
        account.currency = cleanCurrency
        account.group = group
        account.space = space
        account.excluded = excluded
        // Opening balance is a manual-account concept; never clobber a connected account's
        // bank-reported `balance`.
        if account.connection == nil {
            account.balance = openingBalance
            account.manualOpeningBalance = openingBalance
            account.balanceUpdatedAt = openingBalance != nil ? now : nil
        }
        if currencyChanged { markCurrencyOverride(account, now: now) }

        if spaceChanged {
            return try CoreLogic.Transfers.repairGroups(in: ctx, accountId: account.id)
        }
        try ctx.saveTouchingChanges()
        return nil
    }

    @MainActor @discardableResult
    public static func setArchived(
        _ account: Account, _ archived: Bool, in ctx: ModelContext, now: Date = .now
    ) throws -> CoreLogic.Transfers.RepairResult? {
        guard account.archived != archived else { return nil }
        account.archived = archived
        // An approved/unarchived bank account would otherwise only get the incremental
        // window's history; EBSync consumes the flag and does the full lookback.
        if !archived, account.connection != nil {
            var meta = account.metadataJSON
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            meta["fullSyncRequested"] = true
            meta.removeValue(forKey: "pendingApproval")
            account.metadataJSON = try? JSONSerialization.data(withJSONObject: meta)
        }
        // Archiving removes the account from transfer pairing — repair breaks its groups.
        let repair = try CoreLogic.Transfers.repairGroups(in: ctx, accountId: account.id)
        // Unarchiving brings back the route mirrors that archiving deleted.
        if !archived {
            _ = try CoreLogic.TransferRoutes.apply(
                in: ctx, sinceDays: CoreLogic.TransferRoutes.backfillLookbackDays)
        }
        return repair
    }

    // What archiving unpairs, counted on the other accounts' legs: on an active account they
    // stop being transfers, so they count as income or spending again (or stop counting as
    // contributions on an investment account). Legs on accounts already archived count nowhere.
    public struct ArchiveImpact: Equatable, Sendable {
        public var transfers = 0
        // Of those, rows a transfer route copied into the other account; archiving deletes them.
        public var copiesDeleted = 0
        public var counterparts: [String] = []
        public var totalEur: Decimal = 0

        public var isEmpty: Bool { transfers == 0 }

        public var summary: String {
            guard !isEmpty else { return "" }
            let names = Self.joined(counterparts)
            let kept = transfers - copiesDeleted
            func n(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? one : many }
            if copiesDeleted == 0 {
                return transfers == 1
                    ? "Its transfer with \(names) is unpaired and counts as income or spending again."
                    : "Its \(transfers) transfers with \(names) are unpaired and count as income or spending again."
            }
            if kept == 0 {
                return transfers == 1
                    ? "Its transfer with \(names) was copied there by a transfer route and is deleted."
                    : "Its \(transfers) transfers with \(names) were copied there by a transfer route and are deleted."
            }
            return "Its \(transfers) transfers with \(names) are unpaired: "
                + "\(kept) \(n(kept, "counts", "count")) as income or spending again, "
                + "and \(copiesDeleted) that a transfer route copied there \(n(copiesDeleted, "is", "are")) deleted."
        }

        // Spelled out rather than ListFormatter, which would follow the device's language.
        private static func joined(_ names: [String]) -> String {
            guard names.count > 1, let last = names.last else { return names.first ?? "" }
            return names.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    @MainActor
    public static func archiveImpact(of account: Account, in ctx: ModelContext) throws -> ArchiveImpact {
        guard !account.archived else { return ArchiveImpact() }
        let id = account.id
        let plan = try CoreLogic.Transfers.repairPlan(in: ctx, accountId: id, archiving: id)
        var legs: [UUID: Transaction] = [:]
        for t in plan.broken.joined() where t.account?.id != id { legs[t.id] = t }
        for (mirror, source) in plan.mirrors {
            let other = mirror.account?.id == id ? source : mirror
            if other.account?.id != id { legs[other.id] = other }
        }
        let copies = Set(plan.mirrors.map(\.mirror.id))
        let counted = legs.values.filter { CoreLogic.AccountStatus.isUsableForTransfers($0.account) }

        var impact = ArchiveImpact()
        impact.transfers = counted.count
        impact.copiesDeleted = counted.filter { copies.contains($0.id) }.count
        impact.counterparts = Set(counted.compactMap { $0.account?.displayName }).sorted()
        impact.totalEur = counted.reduce(0) { $0 + abs($1.amountEur ?? 0) }
        return impact
    }

    @MainActor
    public static func delete(_ account: Account, in ctx: ModelContext) throws {
        ctx.delete(account)
        try ctx.saveTouchingChanges()
    }

    // Balance anchor: "as of `date`, the real balance was `balance`". The displayed balance
    // then becomes anchor + Σ(tx after date) — see computeEurBalances/computeNativeBalances.
    // anchor and anchorAt are always set/cleared together (the web's PATCH refinement).
    @MainActor
    public static func setAnchor(
        _ account: Account, balance: Decimal, at date: Date, in ctx: ModelContext
    ) throws {
        account.balanceAnchor = balance
        account.balanceAnchorAt = date
        try ctx.saveTouchingChanges()
    }

    @MainActor
    public static func clearAnchor(_ account: Account, in ctx: ModelContext) throws {
        account.balanceAnchor = nil
        account.balanceAnchorAt = nil
        try ctx.saveTouchingChanges()
    }

    // Ports app/api/accounts/[id]/interest: a manual positive credit ("Interest") on the
    // account. externalId "manual-interest:<uuid>", counterparty = institution. EUR amounts
    // are their own EUR value; other currencies get amountEur backfilled by the FX pass.
    @MainActor @discardableResult
    public static func addInterest(
        _ account: Account, amount: Decimal, at date: Date, note: String? = nil,
        in ctx: ModelContext, now: Date = .now
    ) throws -> Transaction {
        guard amount > 0 else { throw MutationError.amountMustBePositive }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEur = account.currency.uppercased() == "EUR"
        let tx = Transaction(
            account: account,
            externalId: "manual-interest:\(UUID().uuidString)",
            bookedAt: date,
            amount: amount,
            currency: account.currency,
            amountEur: isEur ? amount : nil,
            fxRateUsed: isEur ? 1 : nil,
            direction: .credit,
            description: (trimmed?.isEmpty == false ? trimmed : "Interest"),
            counterparty: account.institution,
            categorySource: .bank,
            createdAt: now)
        ctx.insert(tx)
        try ctx.saveTouchingChanges()
        return tx
    }

    // MARK: - Helpers

    private static func requireText(_ value: String, or error: MutationError) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw error }
        return trimmed
    }

    private static func normalizedCurrency(_ raw: String) throws -> String {
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isLetter && $0.isASCII }) else {
            throw MutationError.invalidCurrency
        }
        return code
    }

    private static func markCurrencyOverride(_ account: Account, now: Date) {
        var meta = account.metadataJSON
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        meta["currencyOverride"] = true
        meta["currencyOverrideAt"] = ISO8601DateFormatter().string(from: now)
        account.metadataJSON = try? JSONSerialization.data(withJSONObject: meta)
    }
}
