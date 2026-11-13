import Foundation

/// `GET /api/me` — who the token belongs to. `role` is the effective one (the instance owner is an
/// admin whatever the users table says), which is all the app needs to decide whether to offer
/// admin screens.
public struct MeResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "MeResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case userId = "user_id"
        case email
        case displayName = "display_name"
        case role
        case disabled
    }
    public typealias CodingKeys = ContractKeys

    public enum Role: String, Codable, Sendable, Equatable {
        case admin
        case user
    }

    public let userId: UUID
    public let email: String?
    public let displayName: String
    public let role: Role
    public let disabled: Bool

    public init(userId: UUID, email: String?, displayName: String, role: Role, disabled: Bool) {
        self.userId = userId
        self.email = email
        self.displayName = displayName
        self.role = role
        self.disabled = disabled
    }

    public var isAdmin: Bool { role == .admin }
}

/// `GET /api/auth/config` — answered without a token: what a native client needs to start an
/// authorization-code sign-in. `clientId` is `nil` when this server offers no native sign-in, in
/// which case the app keeps to its none, bearer and basic modes.
public struct AuthConfigResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AuthConfigResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case issuer
        case clientId = "client_id"
        case scopes
        case redirectUri = "redirect_uri"
    }
    public typealias CodingKeys = ContractKeys

    public let issuer: String
    public let clientId: String?
    /// Space-separated, as the authorization request's `scope` parameter wants them.
    public let scopes: String
    public let redirectUri: String

    public init(issuer: String, clientId: String?, scopes: String, redirectUri: String) {
        self.issuer = issuer
        self.clientId = clientId
        self.scopes = scopes
        self.redirectUri = redirectUri
    }
}
