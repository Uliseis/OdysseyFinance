import Foundation
import SwiftData
@testable import CoreBridge
@testable import CoreLogic
@testable import CoreModel

// Synthetic store touching every model and relationship shape the bridge must carry.
// Invented names and round amounts only: the repository is public.
@MainActor
struct BridgeFixture {
    static let now = Date(timeIntervalSince1970: 1_773_144_000) // 2026-03-10 12:00 UTC

    let ctx: ModelContext
    var checking: Account!
    var savings: Account!
    var card: Account!
    var broker: Account!
    var usd: Account!
    var groceries: CoreModel.Category!
    var restaurants: CoreModel.Category!
    var bankRow: Transaction!
    var splitLeg: Transaction!
    var mirroredSource: Transaction!

    static func makeContext() throws -> ModelContext {
        let schema = Schema(CoreModelSchema.allTypes)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    static func day(_ offset: Int) -> Date { now.addingTimeInterval(Double(offset) * 86_400) }

    init() throws {
        ctx = try Self.makeContext()
        try build()
    }

    private mutating func build() throws {
        let personal = AccountSpace(name: "Personal", isDefault: true)
        let shared = AccountSpace(name: "Shared", color: "#225588", isDefault: false, sortOrder: 1)
        let cash = AccountGroup(name: "Cash", color: "#336699", kind: .cash, sortOrder: 2)
        let credit = AccountGroup(name: "Cards", kind: .credit)
        let invest = AccountGroup(name: "Investments", kind: .investment)
        let connection = Connection(
            connector: .enablebanking, institutionId: "EXAMPLE_ES", institutionName: "Example Bank", sessionId: "session-secret",
            accessTokenEnc: "access-secret", refreshTokenEnc: "refresh-secret",
            metadataJSON: Data(#"{"state":"pending-state","country":"ES"}"#.utf8),
            status: .active, expiresAt: Self.day(80), lastSyncAt: Self.day(0))
        [personal, shared].forEach(ctx.insert)
        [cash, credit, invest].forEach(ctx.insert)
        ctx.insert(connection)

        checking = Account(
            connection: connection, group: cash, space: personal, externalId: "uid-checking", type: .bank,
            institution: "Example Bank", name: "Checking", alias: "Main", currency: "EUR", iban: "ES0000000000",
            balance: 1000, balanceUpdatedAt: Self.day(0))
        savings = Account(
            group: cash, space: personal, externalId: "manual-savings", type: .bank, institution: "Example",
            name: "Savings", currency: "EUR", balanceAnchor: 500, balanceAnchorAt: Self.day(-20))
        card = Account(
            group: credit, space: personal, externalId: "manual-card", type: .bank, institution: "Example",
            name: "Card", currency: "EUR",
            metadataJSON: Data(#"{"feedSince":"2026-06-01T00:00:00Z"}"#.utf8), manualOpeningBalance: 0)
        broker = Account(
            group: invest, space: personal, externalId: "manual-broker", type: .broker, institution: "Example",
            name: "Broker", currency: "EUR", manualOpeningBalance: 0, costBasisOpeningEur: 1000,
            costBasisOpeningAt: Self.day(-60), liveValueSource: "coingecko", assetQuantity: Decimal(string: "0.125"))
        usd = Account(
            group: cash, space: shared, externalId: "manual-usd", type: .bank, institution: "Example",
            name: "Dollars", currency: "USD", manualOpeningBalance: 110)
        [checking, savings, card, broker, usd].forEach { ctx.insert($0!) }
        ctx.insert(FxRate(date: Self.day(-1), currency: "USD", rate: Decimal(string: "1.10")!))

        let food = CoreModel.Category(name: "Food", color: "#aa5500")
        groceries = CoreModel.Category(name: "Groceries")
        restaurants = CoreModel.Category(name: "Restaurants", parent: food)
        let salary = CoreModel.Category(name: "Salary", kind: "income")
        [food, groceries, restaurants, salary].forEach { ctx.insert($0!) }
        ctx.insert(CategoryRule(pattern: "SAMPLE MARKET", category: groceries, priority: 10))
        ctx.insert(Budget(category: groceries, amountEur: 300, startsOn: Self.day(-30)))

        func tx(_ account: Account, _ amount: Decimal, _ day: Int, _ text: String,
                category: CoreModel.Category? = nil, source: CategorySource = .bank,
                externalId: String? = nil, raw: Data? = nil) -> Transaction {
            let t = Transaction(
                account: account, externalId: externalId ?? UUID().uuidString, bookedAt: Self.day(day),
                amount: amount, currency: account.currency, amountEur: account.currency == "EUR" ? amount : amount / Decimal(string: "1.10")!,
                direction: amount < 0 ? .debit : .credit, description: text, category: category,
                categorySource: source, rawJSON: raw)
            ctx.insert(t)
            return t
        }

        _ = tx(checking, 2000, -9, "PAYROLL EXAMPLE LTD", category: salary, source: .rule)
        bankRow = tx(checking, -50, -8, "SAMPLE MARKET 01", category: groceries, source: .rule, raw: Data("""
            {"transaction_amount":{"amount":"50.00","currency":"EUR"},"credit_debit_indicator":"DBIT",
             "bank_transaction_code":{"code":"CARD_PAYMENT","description":"Card payment"},
             "creditor":{"name":"SAMPLE MARKET"},"remittance_information":["SAMPLE MARKET 01"]}
            """.utf8))
        _ = tx(card, -40, -7, "EXAMPLE BISTRO", category: restaurants, source: .manual)
        _ = tx(card, 10, -6, "SAMPLE MARKET REFUND", category: groceries, source: .manual)
        _ = tx(checking, 30, -5, "UNKNOWN CREDIT")
        let abroad = tx(usd, -22, -4, "DINER ABROAD")
        abroad.valueAt = Self.day(-3)
        abroad.counterparty = "Example Diner"
        abroad.fxRateUsed = Decimal(string: "1.10")

        let out = tx(checking, -200, -3, "To Savings")
        let into = tx(savings, 200, -3, "From Checking")
        _ = try CoreLogic.Transfers.pairManual(out, into, in: ctx)

        ctx.insert(TransferRoute(pattern: "To Card", sourceAccount: checking, targetAccount: card, direction: .debit, priority: 5))
        mirroredSource = tx(checking, -100, -2, "To Card")
        _ = try CoreLogic.TransferRoutes.apply(in: ctx, txIds: [mirroredSource.id])

        let dinner = tx(checking, -90, -1, "GROUP DINNER", category: restaurants, source: .manual)
        let payback = tx(checking, 45, -1, "PAYBACK FROM FRIEND")
        try CoreLogic.SharedExpenses.createGroup(
            .init(label: "Dinner", primaryTxId: dinner.id, reimbursementTxIds: [payback.id]), in: ctx)

        splitLeg = tx(savings, -25, 0, "Pension split", externalId: "\(CoreLogic.Transfers.internalPrefix)split-1",
                      raw: try JSONEncoder().encode([CoreLogic.Automations.splitMarkerKey: "arrival-1"]))

        ctx.insert(PortfolioValuation(account: broker, asOf: Self.day(-1), marketValueEur: 1100, cashValueEur: 50, notes: "statement"))
        ctx.insert(SyncRun(connector: .enablebanking, connection: connection, startedAt: Self.day(0),
                           finishedAt: Self.day(0), status: .ok, insertedTransactions: 3, error: "partial",
                           rawJSON: Data(#"{"note":"run"}"#.utf8)))
        try ctx.save()
    }

    static let appState = BridgeAppState(
        cycleStartDay: 20, cycleStartsEarlyOnWeekends: true,
        automation: .init(pensionEnabled: false, pensionDeclinedArrivals: ["arrival-0"]))
}
