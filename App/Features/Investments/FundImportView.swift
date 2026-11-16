import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CoreModel
import CoreLogic

// Imports MyInvestor's orders and cash-movements exports into an investment account (D16).
// The orders export has no buy or sell column, so the import also needs the units each fund
// holds today; CoreLogic reads the sides from them and refuses the whole file if they don't fit.
struct FundImportView: View {
    let account: Account
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @State private var orders: Export?
    @State private var movements: Export?
    @State private var units: [UnitsField] = []
    @State private var picking = Kind.orders
    @State private var showingPicker = false
    @State private var problem: String?
    @State private var summary: CoreLogic.FundTrades.ImportSummary?
    @State private var names: [String: String] = [:]

    private enum Kind { case orders, movements }

    private struct Export {
        let fileName: String
        let text: String
    }

    private struct UnitsField: Identifiable {
        let isin: String
        var text: String
        var id: String { isin }
        // Empty means sold. Not a locale-bound number field: under es-ES "12.345" would read as 12345.
        var units: Decimal? { CoreLogic.Transactions.parseQuantity(text) }
        var isInvalid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && units == nil }
    }

    private var canImport: Bool {
        orders != nil && movements != nil && !units.contains(where: \.isInvalid)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let summary {
                    Section {
                        ForEach(FundImportText.summary(summary), id: \.self) { Text($0) }
                    } header: {
                        Text("Imported")
                    } footer: {
                        Text("Each fund's units and gains are on the account's page.")
                    }
                } else {
                    exportsSection
                    if orders != nil { unitsSection }
                    if let problem {
                        Section {
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("MyInvestor Exports")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if summary == nil {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { runImport() }.disabled(!canImport)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .fileImporter(isPresented: $showingPicker,
                          allowedContentTypes: [.commaSeparatedText, .plainText]) { read($0) }
            .task { names = (FundPriceCacheFile().load()?.funds ?? [:]).mapValues(\.name) }
        }
    }

    private var exportsSection: some View {
        Section {
            exportRow("Orders", orders) { pick(.orders) }
            exportRow("Cash movements", movements) { pick(.movements) }
        } header: {
            Text("Exports")
        } footer: {
            Text("Export the fund orders and the account's cash movements from MyInvestor as CSV files, both reaching back to the first order.")
        }
    }

    private func exportRow(_ title: String, _ export: Export?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LabeledContent(title) {
                Text(export?.fileName ?? "Choose…")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(export == nil ? Color.accentColor : Color.secondary)
            }
        }
        .tint(.primary)
    }

    @ViewBuilder
    private var unitsSection: some View {
        Section {
            if units.isEmpty {
                Text("This export has no fund orders.").foregroundStyle(.secondary)
            }
            ForEach($units) { $field in
                LabeledContent {
                    TextField("0", text: $field.text)
                        .multilineTextAlignment(.trailing)
                        .font(.readout(.body, weight: .regular))
                        .keyboardType(.decimalPad)
                        .foregroundStyle(field.isInvalid ? Color.negativeAmount : Color.primary)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[field.isin] ?? field.isin).lineLimit(2)
                        if names[field.isin] != nil {
                            Text(field.isin).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Units held today")
        } footer: {
            Text("Units held today, as MyInvestor shows them; leave empty if sold. A fund imported before starts from its saved units plus this export's new orders as buys: correct it if any of them was a sale.")
        }
    }

    private func pick(_ kind: Kind) {
        picking = kind
        showingPicker = true
    }

    private func read(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            problem = "That file couldn’t be read as text."
            return
        }
        let export = Export(fileName: url.lastPathComponent, text: text)
        do {
            switch picking {
            case .orders:
                let guesses = try CoreLogic.FundTrades.guessHeldUnits(ordersCSV: text, for: account, in: ctx)
                orders = export
                units = guesses.map { UnitsField(isin: $0.isin, text: $0.units.map(Self.unitsText) ?? "") }
            case .movements:
                _ = try CoreLogic.MyInvestorMovementsCSV.parse(text)
                movements = export
            }
            problem = nil
        } catch {
            problem = FundImportText.refusal(error, names: names)
        }
    }

    private func runImport() {
        guard let orders, let movements else { return }
        var held: [String: Decimal] = [:]
        for field in units { held[field.isin] = field.units }
        do {
            summary = try CoreLogic.FundTrades.importOrders(
                ordersCSV: orders.text, movementsCSV: movements.text, heldUnits: held, into: account, in: ctx)
            problem = nil
        } catch {
            problem = FundImportText.refusal(error, names: names)
        }
    }

    // Zero reads as sold, which is what an empty field means. No grouping, so it parses back.
    private static func unitsText(_ units: Decimal) -> String {
        units == 0 ? "" : units.formatted(.number.grouping(.never).precision(.fractionLength(0...6)))
    }
}

#if DEBUG
#Preview {
    FundImportView(account: PreviewData.sampleAccount)
        .modelContainer(PreviewData.container)
}
#endif
