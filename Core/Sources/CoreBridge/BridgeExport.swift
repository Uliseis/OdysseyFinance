import Foundation
import SwiftData
import CoreModel
import CoreLogic
import CoreIntegrations
import CoreSync

public enum BridgeExport {
    public static let syncRunLimit = 50

    // `redact` is for the file that leaves the phone: no session id or tokens, and bank
    // payloads shrink to a BankDetail. rawJSON the app wrote itself (the pension split marker
    // on internal transfers, read by Automations.splitSource) is kept so previews stay exact.
    @MainActor
    public static func make(
        in ctx: ModelContext, appState: BridgeAppState, redact: Bool, now: Date = .now
    ) throws -> BridgeSnapshot {
        var runs = FetchDescriptor<SyncRun>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        runs.fetchLimit = syncRunLimit

        var bankDetails: [BankDetail] = []
        let transactions = try ctx.fetch(FetchDescriptor<Transaction>()).map { tx in
            let s = ModelSnapshots.snapshot(tx)
            guard redact, let raw = s.rawJSON, !s.externalId.hasPrefix(CoreLogic.Transfers.internalPrefix) else { return s }
            if let eb = try? EBJSON.decoder.decode(EbTransaction.self, from: raw) {
                bankDetails.append(BankDetail(
                    txId: s.id, code: eb.bankTransactionCode?.code,
                    codeDescription: eb.bankTransactionCode?.description,
                    creditor: eb.creditor?.name, debtor: eb.debtor?.name))
            }
            return s.withRawJSON(nil)
        }

        return BridgeSnapshot(
            schemaVersion: BridgeSnapshot.currentSchemaVersion,
            exportedAt: now,
            redacted: redact,
            appState: appState,
            connections: try ctx.fetch(FetchDescriptor<Connection>()).map {
                let s = ModelSnapshots.snapshot($0)
                return redact ? s.withoutSecrets() : s
            },
            accountGroups: try ctx.fetch(FetchDescriptor<AccountGroup>()).map(ModelSnapshots.snapshot),
            accountSpaces: try ctx.fetch(FetchDescriptor<AccountSpace>()).map(ModelSnapshots.snapshot),
            accounts: try ctx.fetch(FetchDescriptor<Account>()).map(ModelSnapshots.snapshot),
            categories: try ctx.fetch(FetchDescriptor<CoreModel.Category>()).map(ModelSnapshots.snapshot),
            categoryRules: try ctx.fetch(FetchDescriptor<CategoryRule>()).map(ModelSnapshots.snapshot),
            transferRoutes: try ctx.fetch(FetchDescriptor<TransferRoute>()).map(ModelSnapshots.snapshot),
            transferGroups: try ctx.fetch(FetchDescriptor<TransferGroup>()).map(ModelSnapshots.snapshot),
            budgets: try ctx.fetch(FetchDescriptor<Budget>()).map(ModelSnapshots.snapshot),
            fxRates: try ctx.fetch(FetchDescriptor<FxRate>()).map(ModelSnapshots.snapshot),
            transactions: transactions,
            sharedExpenseGroups: try ctx.fetch(FetchDescriptor<SharedExpenseGroup>()).map(ModelSnapshots.snapshot),
            portfolioValuations: try ctx.fetch(FetchDescriptor<PortfolioValuation>()).map(ModelSnapshots.snapshot),
            syncRuns: try ctx.fetch(runs).map { redact ? ModelSnapshots.snapshot($0).withRawJSON(nil) : ModelSnapshots.snapshot($0) },
            bankDetails: bankDetails
        )
    }
}

extension ConnectionSnapshot {
    func withoutSecrets() -> ConnectionSnapshot {
        ConnectionSnapshot(
            id: id, connector: connector,
            institutionId: institutionId, institutionName: institutionName,
            sessionId: nil, accessTokenEnc: nil, refreshTokenEnc: nil,
            metadataJSON: metadataJSON, status: status,
            expiresAt: expiresAt, lastSyncAt: lastSyncAt, lastError: lastError,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension TransactionSnapshot {
    func withRawJSON(_ raw: Data?) -> TransactionSnapshot {
        TransactionSnapshot(
            id: id, accountId: accountId, externalId: externalId, bookedAt: bookedAt, valueAt: valueAt,
            amount: amount, currency: currency, amountEur: amountEur, fxRateUsed: fxRateUsed,
            direction: direction, transactionDescription: transactionDescription, counterparty: counterparty,
            categoryId: categoryId, categorySource: categorySource, isTransfer: isTransfer,
            transferGroupId: transferGroupId, routedFromTxId: routedFromTxId, routeId: routeId,
            sharedExpenseGroupId: sharedExpenseGroupId, rawJSON: raw, createdAt: createdAt, clock: clock)
    }
}

extension SyncRunSnapshot {
    func withRawJSON(_ raw: Data?) -> SyncRunSnapshot {
        SyncRunSnapshot(
            id: id, connector: connector, connectionId: connectionId, startedAt: startedAt,
            finishedAt: finishedAt, status: status, insertedTransactions: insertedTransactions,
            error: error, rawJSON: raw)
    }
}
