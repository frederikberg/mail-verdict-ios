import Foundation

/// One of the caller's own sign-ins as `GET /api/me/sign-ins` lists it. Only what sign-out needs;
/// `current` marks the sign-in making the request. Not a `ContractModel`: it mirrors the server's
/// `SignInResponse` partially, and the vendored contract snapshot predates that schema.
public struct MVSignIn: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let kind: String
    public let name: String?
    public let revokedAt: Date?
    public let current: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind, name, current
        case revokedAt = "revoked_at"
    }

    public init(id: UUID, kind: String, name: String?, revokedAt: Date?, current: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.revokedAt = revokedAt
        self.current = current
    }
}

extension MVApiClient {

    public func listOwnSignIns() async throws -> [MVSignIn] {
        try await send(path: "/api/me/sign-ins")
    }

    /// Ends one of the caller's sign-ins; the current one included, whose next request is then
    /// refused.
    public func revokeOwnSignIn(id: UUID) async throws {
        let _: MVSignIn = try await send(path: "/api/me/sign-ins/\(id)/revoke", method: "POST")
    }
}
