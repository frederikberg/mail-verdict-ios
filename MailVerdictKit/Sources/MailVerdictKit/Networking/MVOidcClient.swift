import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum MVOidcError: Error, Equatable {
    /// The provider's discovery document could not be read or does not describe this issuer.
    case discoveryFailed(String)
    /// The server offers no native sign-in (`client_id` is null in `GET /api/auth/config`).
    case signInUnavailable
    /// The redirect back to the app carried an error, no code, or a `state` that is not this
    /// attempt's.
    case callbackRejected(String)
    /// The provider answered a token request with a definitive no — an expired, revoked or
    /// already-used code or refresh token. The session is over.
    case rejected(String)
    /// The provider could not be asked, or did not answer sensibly. Says nothing about the
    /// credential.
    case unavailable(String)

    /// Whether the provider refused the credential itself, as opposed to not being reachable.
    public var isRejection: Bool {
        if case .rejected = self { return true }
        return false
    }
}

/// The parts of a provider's `/.well-known/openid-configuration` the sign-in uses.
public struct MVOidcProviderMetadata: Sendable, Equatable, Decodable {
    public let issuer: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
    }
}

/// Talks OIDC to the provider named by `GET /api/auth/config`: discovery, the authorization URL
/// the system browser sheet opens, the code exchange and the refresh grant. It holds no state;
/// `MVTokenRefresher` owns when a refresh happens and where the result is kept.
public struct MVOidcClient: Sendable {
    private let urlSession: URLSession
    private let now: @Sendable () -> Date

    public init(urlSession: URLSession = .mvDefault, now: @escaping @Sendable () -> Date = { Date() }) {
        self.urlSession = urlSession
        self.now = now
    }

    // MARK: Discovery

    public func discover(issuer: String) async throws -> MVOidcProviderMetadata {
        let base = Self.trimmingTrailingSlash(issuer)
        guard let url = URL(string: base + "/.well-known/openid-configuration"),
            let issuerURL = URL(string: base), issuerURL.scheme != nil
        else { throw MVOidcError.discoveryFailed("The sign-in address is not a valid URL.") }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw MVOidcError.unavailable(error.mvUserMessage)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MVOidcError.unavailable("The sign-in provider did not answer.")
        }
        guard let metadata = try? JSONDecoder().decode(MVOidcProviderMetadata.self, from: data) else {
            throw MVOidcError.discoveryFailed("The sign-in provider's configuration could not be read.")
        }
        // A discovery document naming another issuer, or endpoints on a weaker scheme than the
        // issuer itself, would redirect the credential somewhere the server never vouched for.
        guard Self.trimmingTrailingSlash(metadata.issuer) == base,
            metadata.authorizationEndpoint.scheme == issuerURL.scheme,
            metadata.tokenEndpoint.scheme == issuerURL.scheme
        else { throw MVOidcError.discoveryFailed("The sign-in provider's configuration does not match its address.") }
        return metadata
    }

    // MARK: Authorization request

    /// The URL the system browser sheet opens. `state` and `pkce` are the caller's, kept for
    /// `parseCallback` and `exchangeCode`.
    public func authorizationURL(
        config: AuthConfigResponse, metadata: MVOidcProviderMetadata, pkce: MVPkce.Pair, state: String
    ) throws -> URL {
        guard let clientId = config.clientId, !clientId.isEmpty else { throw MVOidcError.signInUnavailable }
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        else { throw MVOidcError.discoveryFailed("The sign-in provider's configuration could not be read.") }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectUri),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        components.queryItems = items
        // A literal `+` in a value would be read back as a space by a form-style query parser.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw MVOidcError.discoveryFailed("The sign-in provider's configuration could not be read.")
        }
        return url
    }

    /// The authorization code in the redirect that ended the browser sheet, once the redirect is
    /// proven to belong to this attempt.
    public func parseCallback(_ callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw MVOidcError.callbackRejected(value("error_description") ?? error)
        }
        guard value("state") == expectedState else {
            throw MVOidcError.callbackRejected("The sign-in answer did not belong to this attempt.")
        }
        guard let code = value("code"), !code.isEmpty else {
            throw MVOidcError.callbackRejected("The sign-in answer carried no code.")
        }
        return code
    }

    // MARK: Token requests

    public func exchangeCode(
        _ code: String, pkce: MVPkce.Pair, config: AuthConfigResponse, metadata: MVOidcProviderMetadata
    ) async throws -> MVOidcTokens {
        guard let clientId = config.clientId, !clientId.isEmpty else { throw MVOidcError.signInUnavailable }
        let response = try await tokenRequest(
            to: metadata.tokenEndpoint,
            form: [
                ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", config.redirectUri),
                ("client_id", clientId), ("code_verifier", pkce.verifier),
            ])
        return try tokens(from: response, issuer: config.issuer, clientId: clientId, previousRefreshToken: nil)
    }

    /// The refresh grant. A provider that rotates refresh tokens returns a new one, which replaces
    /// the old; one that does not leaves the old one in force.
    public func refresh(_ tokens: MVOidcTokens, metadata: MVOidcProviderMetadata) async throws -> MVOidcTokens {
        guard let refreshToken = tokens.refreshToken else { throw MVOidcError.rejected("no_refresh_token") }
        let response = try await tokenRequest(
            to: metadata.tokenEndpoint,
            form: [
                ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                ("client_id", tokens.clientId),
            ])
        return try self.tokens(
            from: response, issuer: tokens.issuer, clientId: tokens.clientId, previousRefreshToken: refreshToken)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Double?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case error
            case errorDescription = "error_description"
        }
    }

    private func tokenRequest(to endpoint: URL, form: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(form).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw MVOidcError.unavailable(error.mvUserMessage)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MVOidcError.unavailable("The sign-in provider did not answer.")
        }
        let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        if (200..<300).contains(http.statusCode) {
            guard let decoded else { throw MVOidcError.unavailable("The sign-in provider's answer could not be read.") }
            return decoded
        }
        // 400/401/403 is the provider refusing the grant. 408, 429 and 5xx are it being busy.
        if [400, 401, 403].contains(http.statusCode) {
            throw MVOidcError.rejected(decoded?.errorDescription ?? decoded?.error ?? "HTTP \(http.statusCode)")
        }
        throw MVOidcError.unavailable("The sign-in provider answered HTTP \(http.statusCode).")
    }

    private func tokens(
        from response: TokenResponse, issuer: String, clientId: String, previousRefreshToken: String?
    ) throws -> MVOidcTokens {
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            throw MVOidcError.unavailable("The sign-in provider's answer carried no token.")
        }
        return MVOidcTokens(
            accessToken: accessToken,
            refreshToken: response.refreshToken ?? previousRefreshToken,
            expiresAt: response.expiresIn.map { now().addingTimeInterval($0) },
            issuer: issuer,
            clientId: clientId
        )
    }

    // MARK: Encoding

    /// `application/x-www-form-urlencoded` with only RFC 3986 unreserved characters left bare, so
    /// a `+` or `=` inside a token cannot be misread as a separator.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        return fields.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    private static func trimmingTrailingSlash(_ text: String) -> String {
        text.hasSuffix("/") ? String(text.dropLast()) : text
    }
}
