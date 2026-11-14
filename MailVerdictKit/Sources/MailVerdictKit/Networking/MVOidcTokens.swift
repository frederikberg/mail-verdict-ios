import Foundation

/// The token set an OIDC sign-in leaves behind. One value, replaced whole on every refresh, so a
/// rotated refresh token can never be stored apart from the access token it arrived with.
public struct MVOidcTokens: Sendable, Equatable, Codable {
    public var accessToken: String
    /// `nil` when the provider issued none (no `offline_access` grant): the session then ends
    /// when the access token does.
    public var refreshToken: String?
    /// `nil` when the provider stated no lifetime; the token is then used until the server
    /// rejects it.
    public var expiresAt: Date?
    public let issuer: String
    public let clientId: String

    public init(
        accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, issuer: String,
        clientId: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.issuer = issuer
        self.clientId = clientId
    }

    /// Whether the access token is expired or about to be, with `skew` seconds of margin for the
    /// request's own travel time and clock drift between phone and provider.
    public func isExpired(at now: Date, skew: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= skew
    }
}
