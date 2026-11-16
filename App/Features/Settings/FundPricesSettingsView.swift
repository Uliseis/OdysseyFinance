import SwiftUI
import CoreIntegrations

// Holds the EODHD API key that prices the funds imported from MyInvestor (D17). Like the
// Trading 212 credentials it lives in the Keychain, never in the store, and is never shown again.
struct FundPricesSettingsView: View {
    @State private var key = ""
    @State private var stored = MarketKeychain().hasEODHD
    @State private var saveFailed = false

    private let keychain = MarketKeychain()

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    SecureField("Paste key", text: $key)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Button("Save Key") { save() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if saveFailed {
                    Text("Couldn't save to the Keychain.").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text(stored ? "Saved" : "Not saved")
            } footer: {
                Text("Create a free API key at eodhd.com and paste it here. It's kept in the Keychain on this device. Prices refresh at most once per fund per day on EODHD's free plan.")
            }

            if stored {
                Section {
                    Button("Remove Key", role: .destructive) {
                        keychain.removeEODHD()
                        stored = false
                    }
                }
            }

            Section {
                Text("Once saved, open the MyInvestor account under Investments and set its value source to Fund prices.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Fund Prices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func save() {
        do {
            try keychain.storeEODHD(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines))
            key = ""
            stored = true
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}
