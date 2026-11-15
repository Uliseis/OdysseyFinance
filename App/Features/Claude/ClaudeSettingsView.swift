import SwiftUI
import SwiftData
import CoreBridge

// Settings → Claude: whether this device takes Claude's changes, which Macs it trusts, what
// may apply without review, and what has been applied (with Undo).
struct ClaudeSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ClaudeSettings.acceptKey) private var accepts = false
    @State private var autoApply = ClaudeSettings.autoApply
    @State private var trusted = ClaudeSettings.trustedKeys
    @State private var results: [BridgeResult] = []
    @State private var pairing = false

    var body: some View {
        List {
            Section {
                Toggle("Accept Changes From Claude", isOn: $accepts)
            } footer: {
                Text("Claude on your Mac can propose changes, like categorizing rows or adding rules. Each batch opens here for review and applies only after Face ID. Only this device applies them.")
            }

            Section {
                ForEach(trusted.values.sorted { $0.createdAt < $1.createdAt }, id: \.keyId) { key in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text(key.label)
                        Text(Self.fingerprint(key))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let sorted = trusted.values.sorted { $0.createdAt < $1.createdAt }
                    for i in offsets { trusted[sorted[i].keyId] = nil }
                    ClaudeSettings.trustedKeys = trusted
                    publish()
                }
                Button("Pair a Mac…") { pairing = true }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text("Batches signed by a paired Mac show as verified. Only those can apply without review.")
            }
            .disabled(!accepts)

            Section {
                ForEach(AutoApplyKind.allCases, id: \.self) { kind in
                    Toggle(ClaudeSettings.title(kind), isOn: binding(kind))
                }
            } header: {
                Text("Apply Without Review")
            } footer: {
                Text("Only for batches from a paired Mac where every change is switched on here; anything else still asks. A program on that Mac that runs Claude’s server could send these too, so switch on only what you’d be happy to undo. Switching one on asks for Face ID.")
            }
            .disabled(!accepts)

            Section("Activity") {
                if results.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(results.prefix(30), id: \.batchId) { result in
                    NavigationLink {
                        ClaudeResultView(result: result) { await reload() }
                    } label: {
                        ClaudeResultRow(result: result)
                    }
                }
            }
        }
        .navigationTitle("Claude")
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: accepts) { publish() }
        .onChange(of: autoApply) { publish() }
        .sheet(isPresented: $pairing, onDismiss: {
            trusted = ClaudeSettings.trustedKeys
            publish()
        }) {
            ClaudePairingView()
        }
    }

    // Turning a switch on lowers protection, so it takes Face ID, and fails closed.
    private func binding(_ kind: AutoApplyKind) -> Binding<Bool> {
        Binding {
            autoApply.contains(kind)
        } set: { on in
            guard on else {
                autoApply.remove(kind)
                ClaudeSettings.autoApply = autoApply
                return
            }
            Task {
                guard await ClaudeInbox.authenticate("Let Claude \(ClaudeSettings.title(kind).lowercased()) without review") else { return }
                autoApply.insert(kind)
                ClaudeSettings.autoApply = autoApply
            }
        }
    }

    // The snapshot carries these settings, so the Mac can tell Claude what the phone will do.
    private func publish() {
        Task { await ClaudeBridge.exportSnapshot(modelContext, force: true) }
    }

    private func reload() async {
        guard let root = await ClaudeBridge.root() else { return }
        results = await Task.detached { ClaudeBridge.results(root) }.value
    }

    static func fingerprint(_ key: BridgePublicKey) -> String {
        (try? BridgeSigning.fingerprint(BridgeSigning.publicKey(key))) ?? key.keyId
    }
}

private struct ClaudeResultRow: View {
    let result: BridgeResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(result.summary.isEmpty ? "Unreadable batch" : result.summary)
                .lineLimit(2)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        var parts = [ClaudeResultView.statusText(result), result.decidedAt.formatted(.dateTime.day().month().hour().minute())]
        if result.decidedBy == .auto { parts.insert("Automatic", at: 1) }
        if result.undoneAt != nil { parts.append("Undone") }
        return parts.joined(separator: " · ")
    }
}

struct ClaudeResultView: View {
    let result: BridgeResult
    let onChange: () async -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUndo = false
    @State private var undoOutcome: BatchOutcome?

    var body: some View {
        List {
            Section {
                if !result.summary.isEmpty { Text(result.summary) }
                LabeledContent("Outcome", value: Self.statusText(result))
                LabeledContent("Decided", value: result.decidedBy == .auto ? "Automatically" : "By you")
                LabeledContent("When", value: result.decidedAt.formatted(date: .abbreviated, time: .shortened))
                ClaudeSenderLabel(sender: result.verified ? .verified(keyId: "") : .unverified, label: nil)
                if let reason = result.reason { Text(reason).foregroundStyle(.secondary) }
                if let undone = result.undoneAt {
                    LabeledContent("Undone", value: undone.formatted(date: .abbreviated, time: .shortened))
                }
            }
            if let undoOutcome, undoOutcome.failedCount > 0 {
                Section("Undo") {
                    Text("\(pluralized(undoOutcome.failedCount, "step")) couldn’t be undone, probably because the data changed since.")
                }
            }
            ForEach(result.outcome?.ops ?? [], id: \.index) { op in
                ClaudeOpSection(op: op, tense: .past)
            }
        }
        .navigationTitle("Batch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if result.undoneAt == nil, result.outcome?.undo != nil, undoOutcome == nil {
                Button("Undo") { confirmingUndo = true }
            }
        }
        .confirmationDialog("Undo this batch?", isPresented: $confirmingUndo, titleVisibility: .visible) {
            Button("Undo Changes", role: .destructive) {
                Task {
                    undoOutcome = await ClaudeInbox.shared.undo(result, in: modelContext)
                    await onChange()
                }
            }
        } message: {
            Text("Rows go back to their previous category, and categories, rules and valuations it created are removed.")
        }
    }

    static func statusText(_ r: BridgeResult) -> String {
        switch r.status {
        case .applied: "Applied"
        case .partial: "Partly applied"
        case .failed: "Failed"
        case .rejected: "Rejected"
        }
    }
}

// Trust a Mac's signing key after checking its fingerprint against what Claude reports.
private struct ClaudePairingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keys: [BridgePublicKey] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if loaded && keys.isEmpty {
                        Text("No Mac has published a key yet. Ask Claude on the Mac for “pairing info”, then come back.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(keys, id: \.keyId) { key in
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(key.label).font(.headline)
                            Text(ClaudeSettingsView.fingerprint(key))
                                .font(.title3.monospaced())
                            Button("Trust This Mac") { Task { await trust(key) } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, Theme.Space.xs)
                    }
                } footer: {
                    Text("Only trust a key whose fingerprint matches the one Claude shows on your Mac.")
                }
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task {
                if let root = await ClaudeBridge.root() {
                    let trusted = ClaudeSettings.trustedKeys
                    keys = await Task.detached { ClaudeBridge.publishedKeys(root) }.value.filter { trusted[$0.keyId] == nil }
                }
                loaded = true
            }
        }
    }

    private func trust(_ key: BridgePublicKey) async {
        guard (try? BridgeSigning.publicKey(key)) != nil,
              await ClaudeInbox.authenticate("Trust \(key.label) to send changes") else { return }
        var trusted = ClaudeSettings.trustedKeys
        trusted[key.keyId] = key
        ClaudeSettings.trustedKeys = trusted
        dismiss()
    }
}
