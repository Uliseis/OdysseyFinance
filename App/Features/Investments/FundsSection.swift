import SwiftUI
import SwiftData
import CoreModel
import CoreLogic

// An investment account's funds, from its imported orders (D16) and the prices cached on this
// device (D17). Read-only: everything here derives from the trades.
struct FundHoldings {
    struct Fund: Identifiable {
        let position: CoreLogic.Funds.Position
        let name: String?
        let price: Decimal?
        let priceCurrency: String?
        let priceDay: Date?
        var id: String { position.isin }
        var label: String { name ?? position.isin }
    }

    let held: [Fund]
    let sold: [Fund]
    let realisedEur: Decimal
    // nil without a broker cash anchor.
    let brokerCashEur: Decimal?

    // nil when the account has no fund trades.
    @MainActor
    static func load(for account: Account, in ctx: ModelContext) -> FundHoldings? {
        guard let trades = try? CoreLogic.FundTrades.trades(for: account, in: ctx), !trades.isEmpty else { return nil }
        let cache = FundPriceCacheFile().load() ?? CoreLogic.FundPriceCache()
        let funds = CoreLogic.Funds.positions(trades, prices: cache.eurPrices).map { position in
            let entry = cache.funds[position.isin]
            return Fund(position: position, name: entry?.name, price: entry?.price,
                        priceCurrency: entry?.currency, priceDay: entry?.priceDay)
        }
        return FundHoldings(
            held: funds.filter { $0.position.units > 0 }.sorted { $0.label < $1.label },
            sold: funds.filter { $0.position.units == 0 }.sorted { $0.label < $1.label },
            realisedEur: funds.reduce(0) { $0 + $1.position.realisedGainEur },
            brokerCashEur: (try? CoreLogic.FundTrades.cashLedger(for: account, in: ctx))?.currentEur)
    }
}

struct FundsSection: View {
    let holdings: FundHoldings?
    // nil hides the import button.
    let onImport: (() -> Void)?

    var body: some View {
        Section {
            if let holdings {
                ForEach(holdings.held) { HeldFundRow(fund: $0) }
                if !holdings.sold.isEmpty {
                    DisclosureGroup("Sold (\(holdings.sold.count))") {
                        ForEach(holdings.sold) { fund in
                            LabeledContent(fund.label) {
                                SignedMoney(amount: fund.position.realisedGainEur)
                            }
                        }
                    }
                }
                LabeledContent("Realised gains") { SignedMoney(amount: holdings.realisedEur) }
                if let cash = holdings.brokerCashEur {
                    LabeledContent("Cash at MyInvestor") { MoneyText(amount: cash) }
                }
            }
            if let onImport {
                Button("Import MyInvestor Exports", systemImage: "square.and.arrow.down", action: onImport)
            }
        } header: {
            Text("Funds")
        } footer: {
            Text(holdings == nil
                 ? "Import MyInvestor's orders and cash movements to follow each fund's units, cost and gains."
                 : "Units and cost from the imported orders, first in, first out. Prices from EODHD, a day behind.")
        }
    }
}

private struct HeldFundRow: View {
    let fund: FundHoldings.Fund
    @Environment(\.dynamicTypeSize) private var typeSize

    private var position: CoreLogic.Funds.Position { fund.position }

    private var details: String {
        var parts = ["\(position.units.formatted(.number.precision(.fractionLength(0...3)))) units"]
        if let average = position.averagePriceEur { parts.append("avg \(FundHoldings.price(average, currency: "EUR"))") }
        return parts.joined(separator: " · ")
    }

    private var priceLine: String {
        guard let price = fund.price, let day = fund.priceDay else { return "No price yet" }
        let on = day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt))
        return "\(FundHoldings.price(price, currency: fund.priceCurrency ?? "EUR")) on \(on)"
    }

    var body: some View {
        AdaptiveStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fund.label).axLineLimit(2)
                Text(details).font(.caption).foregroundStyle(.secondary)
                Text(priceLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.s)
            VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                if let value = position.valueEur {
                    MoneyText(amount: value)
                } else {
                    Text("—").font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let gain = position.unrealisedGainEur {
                    SignedMoney(amount: gain, font: .caption)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// A gain or loss: signed, and coloured by its sign.
private struct SignedMoney: View {
    let amount: Decimal
    var font: Font = .body

    var body: some View {
        let text = Money.format(amount, currency: "EUR")
        Text(amount > 0 ? "+\(text)" : text)
            .font(font.monospacedDigit())
            .fontDesign(.rounded)
            .foregroundStyle(Theme.amountColor(amount))
    }
}

extension FundHoldings {
    // NAVs carry more decimals than money: up to four, like the broker shows them.
    static func price(_ value: Decimal, currency: String) -> String {
        value.formatted(.currency(code: currency).precision(.fractionLength(2...4)))
    }
}

#if DEBUG
#Preview {
    let ctx = PreviewData.container.mainContext
    let account = try? ctx.fetch(FetchDescriptor<Account>(predicate: #Predicate { $0.institution == "MyInvestor" })).first
    List {
        FundsSection(holdings: account.flatMap { FundHoldings.load(for: $0, in: ctx) }, onImport: {})
    }
}
#endif
