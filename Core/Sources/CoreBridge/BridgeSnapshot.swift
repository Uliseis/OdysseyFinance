import Foundation
import CoreLogic
import CoreSync

// Everything the app knows, as one file Claude's MCP server can rebuild into an in-memory
// store and run CoreLogic against (docs/decisions.md D13).
public struct BridgeSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    // True when secrets and bank payloads were stripped for the file that leaves the phone.
    public var redacted: Bool
    public var appState: BridgeAppState

    public var connections: [ConnectionSnapshot]
    public var accountGroups: [AccountGroupSnapshot]
    public var accountSpaces: [AccountSpaceSnapshot]
    public var accounts: [AccountSnapshot]
    public var categories: [CategorySnapshot]
    public var categoryRules: [CategoryRuleSnapshot]
    public var transferRoutes: [TransferRouteSnapshot]
    public var transferGroups: [TransferGroupSnapshot]
    public var budgets: [BudgetSnapshot]
    public var fxRates: [FxRateSnapshot]
    public var transactions: [TransactionSnapshot]
    public var sharedExpenseGroups: [SharedExpenseGroupSnapshot]
    public var portfolioValuations: [PortfolioValuationSnapshot]
    public var syncRuns: [SyncRunSnapshot]
    // What a redacted file keeps of each dropped bank payload.
    public var bankDetails: [BankDetail]
}

public struct BankDetail: Codable, Sendable, Equatable {
    public var txId: UUID
    public var code: String?
    public var codeDescription: String?
    public var creditor: String?
    public var debtor: String?

    public init(txId: UUID, code: String?, codeDescription: String?, creditor: String?, debtor: String?) {
        self.txId = txId; self.code = code; self.codeDescription = codeDescription
        self.creditor = creditor; self.debtor = debtor
    }
}

// Per-device preferences that live in UserDefaults, not SwiftData, but change what the
// numbers and automations do.
public struct BridgeAppState: Codable, Sendable, Equatable {
    public var cycleStartDay: Int
    public var cycleStartsEarlyOnWeekends: Bool
    public var currentSpaceId: UUID?
    public var automation: Automation

    public struct Automation: Codable, Sendable, Equatable {
        public var recurringEnabled: Bool
        public var recurringMuted: [String]
        public var recurringDeclined: [String]
        public var recurringPins: [CoreLogic.Recurring.Pin]
        public var pensionEnabled: Bool
        public var pensionSourceAccountId: UUID?
        public var pensionTargetAccountId: UUID?
        public var pensionAmount: Decimal?
        public var pensionSince: Date?
        public var pensionDeclinedArrivals: [String]

        public init(
            recurringEnabled: Bool = false, recurringMuted: [String] = [], recurringDeclined: [String] = [],
            recurringPins: [CoreLogic.Recurring.Pin] = [], pensionEnabled: Bool = false,
            pensionSourceAccountId: UUID? = nil, pensionTargetAccountId: UUID? = nil,
            pensionAmount: Decimal? = nil, pensionSince: Date? = nil, pensionDeclinedArrivals: [String] = []
        ) {
            self.recurringEnabled = recurringEnabled; self.recurringMuted = recurringMuted
            self.recurringDeclined = recurringDeclined; self.recurringPins = recurringPins
            self.pensionEnabled = pensionEnabled; self.pensionSourceAccountId = pensionSourceAccountId
            self.pensionTargetAccountId = pensionTargetAccountId; self.pensionAmount = pensionAmount
            self.pensionSince = pensionSince; self.pensionDeclinedArrivals = pensionDeclinedArrivals
        }
    }

    public init(
        cycleStartDay: Int = 1, cycleStartsEarlyOnWeekends: Bool = true,
        currentSpaceId: UUID? = nil, automation: Automation = .init()
    ) {
        self.cycleStartDay = cycleStartDay
        self.cycleStartsEarlyOnWeekends = cycleStartsEarlyOnWeekends
        self.currentSpaceId = currentSpaceId
        self.automation = automation
    }

    public var cycle: CoreLogic.Dashboard.Cycle {
        .init(startDay: cycleStartDay, startsEarlyOnWeekends: cycleStartsEarlyOnWeekends)
    }
}

public enum BridgeCoding {
    // Dates stay as seconds since the reference date: exact, unlike ISO 8601 strings.
    public static func encoder() -> JSONEncoder { JSONEncoder() }
    public static func decoder() -> JSONDecoder { JSONDecoder() }
}
