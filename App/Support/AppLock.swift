import SwiftUI
import UIKit
import LocalAuthentication

// The lock screen gets its own window above the app's. Swapping the app's root view for
// it threw away every tab's navigation on each trip to the background, and an overlay
// inside the root wouldn't cover an open sheet, an alert or the bank's auth sheet.
@MainActor @Observable
final class AppLock {
    private(set) var error: String?
    private var window: UIWindow?
    private var authenticating = false

    var isLocked: Bool { window != nil }

    func lock() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first else { return }
        let lockWindow = UIWindow(windowScene: scene)
        lockWindow.windowLevel = .alert + 1
        lockWindow.rootViewController = UIHostingController(rootView: LockScreenHost(lock: self))
        lockWindow.isHidden = false
        window = lockWindow
        error = nil
    }

    func authenticate() {
        guard isLocked, !authenticating else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter passcode"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            error = policyError?.localizedDescription ?? "Biometrics unavailable"
            return
        }
        authenticating = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Odyssey Finance") { success, evalError in
            let message = evalError?.localizedDescription
            Task { @MainActor in
                self.authenticating = false
                if success { self.unlock() } else { self.error = message }
            }
        }
    }

    private func unlock() {
        window?.isHidden = true
        window = nil
        error = nil
    }
}

private struct LockScreenHost: View {
    let lock: AppLock

    var body: some View {
        LockScreen(error: lock.error, onUnlock: lock.authenticate)
    }
}
