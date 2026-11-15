import SwiftUI
import SwiftData
import AuthenticationServices
import CoreModel
import CoreLogic
import CoreIntegrations

// The registered Enable Banking redirect URL for iOS. EB rejects private-use schemes, so
// this is https — which means the app must be associated with the host: the entitlement in
// project.yml plus the AASA in Vercel/. Inside the auth session the load is intercepted;
// when a bank app opens it in Safari instead, Vercel/ios-callback.html forwards it to
// `appScheme` (registered in project.yml).
enum EBConfig {
    static let redirectURL = URL(string: "https://odysseyfinance.vercel.app/enablebanking/ios-callback")!
    static let appScheme = "odysseyfinance"
    static var callbackHost: String { redirectURL.host() ?? "" }
    static var callbackPath: String { redirectURL.path() }
}

// Full bank-link round trip: startAuth → in-app browser → callback code → createSession →
// Connection row updated. Used for both first-time links and re-auth (existing != nil).
@MainActor
enum BankLink {
    struct Outcome {
        let institution: String
        let authorized: Bool
        let accountCount: Int
    }

    static func link(
        aspspName: String, country: String,
        existing: Connection? = nil, in ctx: ModelContext
    ) async throws -> Outcome {
        let client = try makeClient()
        let state = UUID().uuidString
        let (request, validUntil) = CoreLogic.EBConnect.makeAuthRequest(
            aspspName: aspspName, country: country,
            redirectUrl: EBConfig.redirectURL.absoluteString, state: state)
        let auth = try await client.startAuth(request)
        let connection = try CoreLogic.EBConnect.prepareConnection(
            existing: existing, aspspName: aspspName, country: country,
            state: state, authorizationId: auth.authorizationId,
            validUntil: validUntil, in: ctx)
        guard let authURL = URL(string: auth.url) else { throw URLError(.badURL) }

        let callback = try await BankAuthSession.authenticate(url: authURL)
        return try await finish(callback: callback, connection: connection, client: client, in: ctx)
    }

    // The redirect reached the app from outside the auth session: the bank's own app did
    // SCA and opened it in Safari. Any auth sheet still open is stale, so it's closed (its
    // link() ends as a cancellation) and the pending connection is found by the state it
    // stored before the browser opened. nil when the URL isn't a bank callback or its
    // connection was already finished.
    static func completeExternal(_ url: URL, in ctx: ModelContext) async throws -> Outcome? {
        guard CoreLogic.EBConnect.isCallback(
            url, redirect: EBConfig.redirectURL, appScheme: EBConfig.appScheme) else { return nil }
        BankAuthSession.cancel()
        let (_, state) = try CoreLogic.EBConnect.parseCallback(url)
        guard let connection = try CoreLogic.EBConnect.pendingConnection(forState: state, in: ctx)
        else { return nil }
        do {
            return try await finish(callback: url, connection: connection, client: makeClient(), in: ctx)
        } catch {
            connection.lastError = String(describing: error)
            try? ctx.saveTouchingChanges()
            throw error
        }
    }

    private static func makeClient() throws -> EBClient {
        EBClient(tokenProvider: try EBKeychain().loadSigner())
    }

    private static func finish(
        callback: URL, connection: Connection, client: EBClient, in ctx: ModelContext
    ) async throws -> Outcome {
        let (code, returnedState) = try CoreLogic.EBConnect.parseCallback(callback)
        let session = try await client.createSession(code: code)
        // POST /sessions returns no status, so the freshly created session is asked for its
        // own — the same GET the sync uses, and the only authority on whether it's usable.
        let status = try await client.getSession(session.sessionId).status
        try CoreLogic.EBConnect.applySession(
            session, status: status, to: connection, expectedState: returnedState, in: ctx)
        return Outcome(
            institution: connection.institutionName ?? "The bank",
            authorized: status == "AUTHORIZED",
            accountCount: EBHelpers.sessionAccounts(session).count)
    }
}

// ASWebAuthenticationSession wrapper. The session and its context provider must stay
// alive until the completion fires.
@MainActor
private enum BankAuthSession {
    private static var active: (ASWebAuthenticationSession, WebAuthContext)?

    static func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let context = WebAuthContext()
            let session = ASWebAuthenticationSession(
                url: url,
                callback: .https(host: EBConfig.callbackHost, path: EBConfig.callbackPath)
            ) { callbackURL, error in
                Task { @MainActor in active = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
            session.presentationContextProvider = context
            active = (session, context)
            if !session.start() {
                active = nil
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    // Fires the session's own completion with .canceledLogin, so its continuation resumes once.
    static func cancel() {
        active?.0.cancel()
    }
}

private final class WebAuthContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.compactMap(\.keyWindow).first ?? scenes.flatMap(\.windows).first {
            return window
        }
        guard let scene = scenes.first else {
            preconditionFailure("Auth session started with no connected window scene")
        }
        return UIWindow(windowScene: scene)
    }
}

extension Error {
    // User-closed auth sheet — not an error worth surfacing.
    var isAuthCancellation: Bool {
        self is CancellationError ||
        (self as? ASWebAuthenticationSessionError)?.code == .canceledLogin
    }
}
