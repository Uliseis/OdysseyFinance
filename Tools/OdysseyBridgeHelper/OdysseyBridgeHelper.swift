import SwiftUI

// macOS syncs an app's private iCloud Drive container only while an app that names it is
// installed, so this app exists to claim the container the Claude bridge uses (D15).
@main
struct OdysseyBridgeHelper: App {
    var body: some Scene {
        Window("Odyssey Bridge", id: "main") { StatusView() }
            .windowResizability(.contentSize)
    }
}

struct StatusView: View {
    @State private var status = "Checking iCloud…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Odyssey Bridge").font(.headline)
            Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Keep this app installed so the Mac syncs the folder Claude reads. It doesn't need to stay open.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .task { status = await Self.check() }
    }

    // The lookup also registers the container with iCloud on this Mac. It can block, so off main.
    static func check() async -> String {
        await Task.detached(priority: .utility) {
            guard let root = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.com.uliseis.odysseyfinance") else {
                return "iCloud Drive is off, or this Mac isn't signed in to iCloud."
            }
            let bridge = root.appending(path: "bridge", directoryHint: .isDirectory)
            try? FileManager.default.startDownloadingUbiquitousItem(at: bridge)
            return FileManager.default.fileExists(atPath: bridge.path)
                ? "Syncing \(bridge.path)"
                : "Waiting for the phone's files in \(root.path)"
        }.value
    }
}
