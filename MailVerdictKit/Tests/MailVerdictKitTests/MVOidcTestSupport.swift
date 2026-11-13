import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import MailVerdictKit

/// Shared stub answers for the sign-in tests: one provider at `login.example.com`, one backend at
/// `mail.example.com`, both served by `MVStubURLProtocol`.
enum MVOidcFixtures {
    static let issuer = "https://login.example.com"
    static let clientId = "native-client"

    static let config = AuthConfigResponse(
        issuer: issuer, clientId: clientId, scopes: "openid profile email offline_access",
        redirectUri: "mailverdict://auth/callback")

    static func tokens(access: String = "access-1", refresh: String? = "refresh-1", expiresAt: Date? = nil)
        -> MVOidcTokens
    {
        MVOidcTokens(
            accessToken: access, refreshToken: refresh, expiresAt: expiresAt, issuer: issuer, clientId: clientId)
    }

    static func discovery(issuer: String = issuer) -> MVStubURLProtocol.Stub {
        .init(
            statusCode: 200, headers: [:],
            body: Data(
                """
                {"issuer":"\(issuer)","authorization_endpoint":"\(Self.issuer)/oauth/v2/authorize",
                "token_endpoint":"\(Self.issuer)/oauth/v2/token"}
                """.utf8))
    }

    static func tokenAnswer(access: String, refresh: String?, expiresIn: Int = 3600) -> MVStubURLProtocol.Stub {
        let refreshField = refresh.map { #","refresh_token":"\#($0)""# } ?? ""
        return .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"access_token":"\#(access)"\#(refreshField),"expires_in":\#(expiresIn)}"#.utf8))
    }

    static func tokenRefusal(status: Int = 400, error: String = "invalid_grant") -> MVStubURLProtocol.Stub {
        .init(
            statusCode: status, headers: ["Content-Type": "application/json"],
            body: Data(#"{"error":"\#(error)"}"#.utf8))
    }

    static func jsonError(status: Int, detail: String) -> MVStubURLProtocol.Stub {
        .init(
            statusCode: status, headers: ["Content-Type": "application/json"],
            body: Data(#"{"detail":"\#(detail)"}"#.utf8))
    }

    /// What the login proxy answers an invalid bearer with: a bare, non-JSON 403.
    static let proxyForbidden = MVStubURLProtocol.Stub(
        statusCode: 403, headers: ["Content-Type": "text/plain"], body: Data("Forbidden".utf8))

    static func ok(_ json: String = "{}") -> MVStubURLProtocol.Stub {
        .init(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    static func requestBody(_ request: URLRequest?) -> String {
        String(decoding: request?.httpBody ?? Data(), as: UTF8.self)
    }
}

/// Collects what a `@Sendable` callback reports, for assertions after the awaited call returns.
final class MVCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func record(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
