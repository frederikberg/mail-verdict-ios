import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class MVSignInsTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func client() throws -> MVApiClient {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", deviceName: "Test iPhone", authProvider: { .none })
        return MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
    }

    private let row = """
        {"id":"00000000-0000-0000-0000-000000000001","user_id":"00000000-0000-0000-0000-000000000002",
        "kind":"phone","name":"iPhone","subject":"s","first_seen_at":"2026-01-01T00:00:00Z",
        "last_seen_at":"2026-01-02T00:00:00Z","revoked_at":null,"current":true}
        """

    func testTheCurrentSignInIsTheOneMarkedCurrent() async throws {
        MVStubURLProtocol.stub = MVOidcFixtures.ok("[\(row)]")
        let signIns = try await client().listOwnSignIns()
        XCTAssertEqual(signIns.first { $0.current }?.name, "iPhone")
        XCTAssertEqual(MVStubURLProtocol.capturedRequest?.url?.path, "/api/me/sign-ins")
    }

    func testRevokingPostsToTheSignInsRevokeRoute() async throws {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(row)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        try await client().revokeOwnSignIn(id: id)
        let request = try XCTUnwrap(MVStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/me/sign-ins/\(id.uuidString.lowercased())/revoke")
    }
}
