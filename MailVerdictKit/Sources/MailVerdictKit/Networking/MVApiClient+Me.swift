import Foundation

extension MVApiClient {

    public func getMe() async throws -> MeResponse {
        try await send(path: "/api/me")
    }

    /// Public: the sign-in screen reads it before any token exists.
    public func getAuthConfig() async throws -> AuthConfigResponse {
        try await send(path: "/api/auth/config")
    }
}
