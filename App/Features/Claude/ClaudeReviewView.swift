import SwiftUI
import SwiftData
import CoreBridge

// One batch from Claude: what it says it does, who sent it, what it changes and what that
// does to the numbers. Approving asks for Face ID; swiping it away decides later.
struct ClaudeReviewView: View {
    let item: PendingBatch
    @Environment(\.modelContext) private var modelContext
    @State private var working = false

    private var outcome: BatchOutcome { item.preview.outcome }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(item.batch.summary)
                        .font(.body)
                    ClaudeSenderLabel(sender: item.sender, label: item.senderLabel)
                    if outcome.undo == nil && outcome.appliedCount > 0 {
                        Label("Can’t be undone", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if !item.sender.isVerified {
                            Text("Not signed by a Mac paired in Settings → Claude. Anything on your Mac or another device on your iCloud account could have written it. Read it carefully.")
                        }
                        if outcome.undo == nil && outcome.appliedCount > 0 {
                            Text("Changes marked below as permanent have no Undo, so nothing in this batch can be undone after you approve.")
                        }
                    }
                }
                Section("Effect") {
                    ClaudeEffectRow(title: "Net Worth", before: item.preview.before.netWorth, after: item.preview.after.netWorth)
                    ClaudeEffectRow(title: "Income This Month", before: item.preview.before.cycleIncome, after: item.preview.after.cycleIncome)
                    ClaudeEffectRow(title: "Spending This Month", before: item.preview.before.cycleExpense, after: item.preview.after.cycleExpense)
                    LabeledContent("Uncategorized",
                                   value: "\(item.preview.before.uncategorized) → \(item.preview.after.uncategorized)")
                }
                if !item.preview.months.isEmpty {
                    Section {
                        ForEach(item.preview.months, id: \.start) { month in
                            ClaudeMonthRow(month: month)
                        }
                    } header: {
                        Text("Months Affected")
                    } footer: {
                        Text("Every pay cycle whose income or spending this batch changes.")
                    }
                }
                ForEach(outcome.ops, id: \.index) { op in
                    ClaudeOpSection(op: op, tense: .preview,
                                    permanent: item.batch.ops.indices.contains(op.index) && !item.batch.ops[op.index].isUndoable)
                }
            }
            .navigationTitle("Claude’s Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject", role: .destructive) {
                        Task { await ClaudeInbox.shared.reject(item) }
                    }
                    .disabled(working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Approve") {
                        working = true
                        Task {
                            await ClaudeInbox.shared.approve(item, in: modelContext)
                            working = false
                        }
                    }
                    .disabled(working || outcome.appliedCount == 0)
                }
            }
        }
    }
}

struct ClaudeSenderLabel: View {
    let sender: BridgeSender
    let label: String?

    var body: some View {
        if sender.isVerified {
            Label("From \(label ?? "a paired Mac")", systemImage: "checkmark.seal.fill")
                .foregroundStyle(Color.brand)
        } else {
            Label("Unverified sender", systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
        }
    }
}

struct ClaudeMonthRow: View {
    let month: MonthChange

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("\(month.start.formatted(.dateTime.day().month().year())) – \(month.end.addingTimeInterval(-1).formatted(.dateTime.day().month()))")
                .font(.subheadline.weight(.medium))
            if month.expenseBefore != month.expenseAfter {
                Text("Spending \(Money.format(month.expenseBefore, currency: "EUR")) → \(Money.format(month.expenseAfter, currency: "EUR"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if month.incomeBefore != month.incomeAfter {
                Text("Income \(Money.format(month.incomeBefore, currency: "EUR")) → \(Money.format(month.incomeAfter, currency: "EUR"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
    }
}

struct ClaudeEffectRow: View {
    let title: String
    let before: Decimal
    let after: Decimal

    var body: some View {
        LabeledContent(title) {
            if before == after {
                Text(Money.format(after, currency: "EUR"))
            } else {
                Text("\(Money.format(before, currency: "EUR")) → \(Money.format(after, currency: "EUR"))")
                    .foregroundStyle(.primary)
            }
        }
        .monospacedDigit()
    }
}

// One op of a batch, as a preview ("will apply") or as a recorded outcome ("applied").
struct ClaudeOpSection: View {
    enum Tense { case preview, past }
    let op: OpOutcome
    let tense: Tense
    var permanent = false
    private let shown = 50

    var body: some View {
        Section {
            ForEach(Array(op.changes.prefix(shown).enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(change.label)
                        .font(.subheadline)
                        .lineLimit(2)
                    if let text = Self.transition(change) {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if op.changes.count > shown {
                Text("And \(op.changes.count - shown) more")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Label(Self.title(op.op), systemImage: icon)
                .foregroundStyle(color)
        } footer: {
            Text("\(statusText). \(op.message)" + (permanent && op.status == .applied ? " Permanent: no Undo." : ""))
        }
    }

    private var icon: String {
        switch op.status {
        case .applied: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch op.status {
        case .applied: Color.brand
        case .skipped: .secondary
        case .failed: .orange
        }
    }

    private var statusText: String {
        switch (op.status, tense) {
        case (.applied, .preview): "Will apply"
        case (.applied, .past): "Applied"
        case (.skipped, _): "No change"
        case (.failed, .preview): "Will fail and be skipped"
        case (.failed, .past): "Failed"
        }
    }

    // A new item shows only what it becomes; a removed one shows what goes.
    static func transition(_ change: BridgeChange) -> String? {
        switch (change.before, change.after) {
        case (nil, nil): nil
        case (nil, let after?): after
        case (let before?, nil): "\(before) → removed"
        case (let before?, let after?): "\(before) → \(after)"
        }
    }

    static func title(_ op: String) -> String {
        switch op {
        case "categorize": "Categorize"
        case "createCategory": "New Category"
        case "createRule": "New Rule"
        case "updateRule": "Edit Rule"
        case "deleteRule": "Delete Rule"
        case "applyRules": "Re-run Rules"
        case "pairTransfer": "Pair Transfer"
        case "unpairTransfer": "Unpair Transfer"
        case "createSharedGroup": "Shared Expense"
        case "deleteSharedGroup": "Dissolve Shared Expense"
        case "recordValuation": "Record Valuation"
        case "importStatement": "Import Statement"
        case "deleteTransactions": "Delete Rows"
        case "adoptFeed": "Adopt Bank Feed"
        case "undoPensionSplit": "Undo Pension Split"
        case "createRoute": "New Transfer Route"
        case "updateRoute": "Edit Transfer Route"
        case "deleteRoute": "Delete Transfer Route"
        case "requestBankSync": "Sync Banks"
        case "requestReconnect": "Reconnect Bank"
        case "createTransaction": "New Row"
        case "mirrorTransfer": "Mirror Transfer"
        case "createSharedGroupFromCredit": "Shared Expense From a Payback"
        case "archiveAccount": "Archive Account"
        case "restoreCategories": "Restore Categories"
        case "deleteCategory": "Remove Category"
        case "deleteValuation": "Remove Valuation"
        default: op
        }
    }
}
