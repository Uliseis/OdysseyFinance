import Foundation
import SwiftData
import UIKit
import LocalAuthentication
import UserNotifications
import CoreBridge

struct PendingBatch: Identifiable {
    let batch: BridgeBatch
    let sender: BridgeSender
    let senderLabel: String?
    let preview: BatchPreview
    var id: UUID { batch.id }
}

// Claude's change batches arriving in bridge/inbox/ (docs/decisions.md D13). Each is previewed
// on a copy of the data; a batch signed by a paired Mac whose ops are all switched on for
// auto-apply is applied straight away, everything else waits for review and Face ID. The
// outcome goes to bridge/results/ and the inbox file is removed.
@MainActor @Observable
final class ClaudeInbox {
    static let shared = ClaudeInbox()

    private(set) var pending: [PendingBatch] = []
    // The batch the review sheet shows.
    var current: PendingBatch?
    var error: String?
    private var refreshing = false

    func refresh(_ ctx: ModelContext) async {
        guard ClaudeSettings.acceptsChanges, !refreshing, let root = await ClaudeBridge.root() else { return }
        refreshing = true
        defer { refreshing = false }
        let inbox = root.appending(path: BridgePaths.inbox, directoryHint: .isDirectory)
        let files = await Task.detached { ClaudeBridge.list(inbox) }.value
        for url in files {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !ClaudeSettings.isProcessed(id), !pending.contains(where: { $0.id == id }) else { continue }
            // A read can fail while iCloud is still downloading; try again next time.
            guard let data = try? await Task.detached(operation: { try ClaudeBridge.read(url) }).value else { continue }
            do {
                let envelope = try BridgeCoding.decoder().decode(BridgeEnvelope.self, from: data)
                let (batch, sender) = try BridgeSigning.open(envelope, trusted: ClaudeSettings.verifiers)
                let preview = try BridgeReplica(BridgeExport.make(in: ctx, appState: ClaudeBridge.appState, redact: false))
                    .preview(batch)
                if sender.isVerified, let kinds = preview.outcome.autoApplyKinds,
                   Set(kinds).isSubset(of: ClaudeSettings.autoApply) {
                    await apply(batch, sender: sender, decidedBy: .auto, root: root, in: ctx)
                } else {
                    let label = if case .verified(let keyId) = sender { ClaudeSettings.trustedKeys[keyId]?.label } else { String?.none }
                    pending.append(PendingBatch(batch: batch, sender: sender, senderLabel: label, preview: preview))
                }
            } catch {
                // Forged, altered or malformed: never applied, and the Mac learns why.
                await record(BridgeResult(batchId: id, summary: "", status: .rejected, decidedAt: .now,
                                          decidedBy: .auto, verified: false, reason: "\(error)"), root: root)
            }
        }
        if current == nil { current = pending.first }
    }

    func approve(_ item: PendingBatch, in ctx: ModelContext) async {
        guard await Self.authenticate("Apply Claude’s changes"), let root = await ClaudeBridge.root() else { return }
        await apply(item.batch, sender: item.sender, decidedBy: .user, root: root, in: ctx)
    }

    func reject(_ item: PendingBatch) async {
        guard let root = await ClaudeBridge.root() else { return }
        await record(BridgeResult(batchId: item.id, summary: item.batch.summary, status: .rejected, decidedAt: .now,
                                  decidedBy: .user, verified: item.sender.isVerified, reason: "Rejected on the phone"),
                     root: root)
    }

    // Runs a batch's undo ops and stamps the result, so Claude sees it was reverted.
    func undo(_ result: BridgeResult, in ctx: ModelContext) async -> BatchOutcome? {
        guard result.undoneAt == nil, let ops = result.outcome?.undo, let root = await ClaudeBridge.root() else { return nil }
        let outcome = BridgeExecutor.run(BridgeBatch(summary: "Undo: \(result.summary)", ops: ops), in: ctx)
        var stamped = result
        stamped.undoneAt = .now
        await write(stamped, root: root)
        await ClaudeBridge.exportSnapshot(ctx, force: true)
        return outcome
    }

    private func apply(_ batch: BridgeBatch, sender: BridgeSender, decidedBy: BridgeResult.Decider,
                       root: URL, in ctx: ModelContext) async {
        let outcome = BridgeExecutor.run(batch, in: ctx)
        let result = BridgeResult(batchId: batch.id, summary: batch.summary, status: BridgeResult.status(of: outcome),
                                  decidedAt: .now, decidedBy: decidedBy, verified: sender.isVerified, outcome: outcome)
        await record(result, root: root)
        if decidedBy == .auto, UIApplication.shared.applicationState != .active { await Self.notify(result) }
        await ClaudeBridge.exportSnapshot(ctx, force: true)
    }

    private func record(_ result: BridgeResult, root: URL) async {
        ClaudeSettings.markProcessed(result.batchId)
        pending.removeAll { $0.id == result.batchId }
        if current?.id == result.batchId { current = pending.first }
        await write(result, root: root)
        let inboxFile = root.appending(path: BridgePaths.inbox).appending(path: BridgePaths.file(for: result.batchId))
        try? await Task.detached { try ClaudeBridge.remove(inboxFile) }.value
    }

    private func write(_ result: BridgeResult, root: URL) async {
        let url = root.appending(path: BridgePaths.results).appending(path: BridgePaths.file(for: result.batchId))
        do {
            let data = try BridgeCoding.encoder().encode(result)
            try await Task.detached { try ClaudeBridge.write(data, to: url) }.value
        } catch {
            self.error = "Couldn’t save the outcome for Claude: \(error.localizedDescription)"
        }
    }

    static func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    private static func notify(_ result: BridgeResult) async {
        let content = UNMutableNotificationContent()
        content.title = "Claude applied changes"
        let count = result.outcome?.appliedCount ?? 0
        content.body = "\(result.summary) (\(pluralized(count, "change"))). Undo in Settings → Claude."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "claude-\(result.batchId.uuidString)", content: content, trigger: nil))
    }
}
