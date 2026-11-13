import AuthenticationServices
import MailVerdictKit
import UIKit

/// Runs the single sign-in: asks the server which provider to use, opens it in the system browser
/// sheet, and trades what comes back for a token set.
///
/// The sheet shares cookies with Safari, so a person already signed in to the provider is not asked
/// for a password again. The redirect scheme needs no Info.plist entry: the session intercepts its
/// own callback.
@MainActor
final class OidcSignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {

    enum Outcome {
        case signedIn(MVOidcTokens)
        /// The person closed the sheet.
        case cancelled
    }

    /// Why a sign-in could not start or finish, in words for the sign-in screen.
    struct Failure: Error {
        let message: String
        /// The server offers no single sign-in, so the manual modes are the way in.
        let unavailable: Bool
    }

    private let oidc = MVOidcClient()
    private var session: ASWebAuthenticationSession?

    /// Read by the system on its own schedule, so it cannot be actor-isolated; set right before the
    /// sheet starts.
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

    func signIn(backendURL: String) async throws -> Outcome {
        let base = backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let config: AuthConfigResponse
        do {
            let factory = try MVRequestFactory(baseURL: base, authProvider: { .none })
            config = try await MVApiClient(requestFactory: factory).getAuthConfig()
        } catch {
            throw Failure(message: error.mvUserMessage, unavailable: false)
        }
        guard config.clientId != nil else {
            throw Failure(message: "This server has no single sign-in.", unavailable: true)
        }

        do {
            let metadata = try await oidc.discover(issuer: config.issuer)
            let pkce = MVPkce.makePair()
            let state = MVPkce.randomURLSafeString()
            let url = try oidc.authorizationURL(config: config, metadata: metadata, pkce: pkce, state: state)
            guard let scheme = URL(string: config.redirectUri)?.scheme else {
                throw Failure(message: "The server's sign-in address could not be used.", unavailable: false)
            }
            guard let callback = try await present(url, callbackScheme: scheme) else { return .cancelled }
            let code = try oidc.parseCallback(callback, expectedState: state)
            let tokens = try await oidc.exchangeCode(code, pkce: pkce, config: config, metadata: metadata)
            return .signedIn(tokens)
        } catch let failure as Failure {
            throw failure
        } catch let error as MVOidcError {
            throw Failure(message: Self.message(for: error), unavailable: error == .signInUnavailable)
        }
    }

    /// The redirect that ended the sheet, or `nil` when the person closed it.
    private func present(_ url: URL, callbackScheme: String) async throws -> URL? {
        anchor = Self.keyWindow()
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: .success(callback))
                } else {
                    continuation.resume(returning: .failure(error ?? CocoaError(.userCancelled)))
                }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() {
                continuation.resume(
                    returning: .failure(Failure(message: "The sign-in sheet could not be opened.", unavailable: false)))
            }
        }
        session = nil
        switch result {
        case .success(let callback): return callback
        case .failure(let error as ASWebAuthenticationSessionError) where error.code == .canceledLogin: return nil
        case .failure(let error as Failure): throw error
        case .failure(let error): throw Failure(message: error.mvUserMessage, unavailable: false)
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func message(for error: MVOidcError) -> String {
        switch error {
        case .discoveryFailed(let text), .callbackRejected(let text), .rejected(let text), .unavailable(let text):
            return text
        case .signInUnavailable:
            return "This server has no single sign-in."
        }
    }
}
