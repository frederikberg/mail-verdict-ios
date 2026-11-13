import XCTest

@testable import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The status rules of an OIDC session, driven through the real client, refresher and provider
/// client over one stub: which answers refresh, which sign out, which do neither.
final class MVApiClientOidcTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private struct Rig {
        let client: MVApiClient
        let holder: MVOidcTokenHolder
        let signedOut: MVCallLog
    }

    private func makeRig() throws -> Rig {
        let holder = MVOidcTokenHolder(MVOidcFixtures.tokens())
        let session = MVStubURLProtocol.makeSession()
        let refresher = MVTokenRefresher(
            holder: holder, client: MVOidcClient(urlSession: session), persist: { _ in })
        let signedOut = MVCallLog()
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", authProvider: { holder.authMode })
        let client = MVApiClient(
            requestFactory: factory, urlSession: session,
            onAuthenticationFailure: { signedOut.record($0.userMessage) },
            credentialRefresher: refresher)
        return Rig(client: client, holder: holder, signedOut: signedOut)
    }

    private func bearers() -> [String?] {
        MVStubURLProtocol.capturedRequests
            .filter { $0.url?.path == "/api/me" }
            .map { $0.value(forHTTPHeaderField: "Authorization") }
    }

    private static let meJSON = """
        {"user_id":"00000000-0000-0000-0000-000000000001","email":null,"display_name":"Owner",
        "role":"admin","disabled":false}
        """

    func testBearerIsTheAccessToken() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.stub = MVOidcFixtures.ok(Self.meJSON)
        let me = try await rig.client.getMe()
        XCTAssertTrue(me.isAdmin)
        XCTAssertEqual(bearers(), ["Bearer access-1"])
    }

    func testA401RefreshesAndRetriesOnceWithTheNewToken() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.queue = [
            MVOidcFixtures.jsonError(status: 401, detail: "not_authenticated"),
            MVOidcFixtures.discovery(),
            MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2"),
            MVOidcFixtures.ok(Self.meJSON),
        ]
        _ = try await rig.client.getMe()
        XCTAssertEqual(bearers(), ["Bearer access-1", "Bearer access-2"])
        XCTAssertTrue(rig.signedOut.all.isEmpty)
    }

    /// The proxy answers an invalid token with a bare 403, which must read as a rejected
    /// credential: refresh once, and if the new token is refused too, sign out.
    func testTheProxys403RefreshesOnceThenSignsOut() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.queue = [
            MVOidcFixtures.proxyForbidden,
            MVOidcFixtures.discovery(),
            MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2"),
            MVOidcFixtures.proxyForbidden,
        ]
        do {
            _ = try await rig.client.getMe()
            XCTFail("expected an error")
        } catch let error as MVError {
            XCTAssertTrue(error.isAuthenticationFailure)
        }
        XCTAssertEqual(bearers(), ["Bearer access-1", "Bearer access-2"])
        XCTAssertEqual(rig.signedOut.all.count, 1)
    }

    func testARefusedRefreshTokenSignsOutAfterOneTokenRequest() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.queue = [
            MVOidcFixtures.jsonError(status: 401, detail: "not_authenticated"),
            MVOidcFixtures.discovery(),
            MVOidcFixtures.tokenRefusal(),
        ]
        do {
            _ = try await rig.client.getMe()
            XCTFail("expected an error")
        } catch let error as MVError {
            XCTAssertTrue(error.isAuthenticationFailure)
        }
        XCTAssertEqual(bearers().count, 1)
        XCTAssertEqual(rig.signedOut.all.count, 1)
    }

    /// An unreachable provider says nothing about the credential: the person stays signed in and
    /// sees a connection error, not a sign-in screen.
    func testAnUnreachableProviderDoesNotSignOut() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.queue = [
            MVOidcFixtures.jsonError(status: 401, detail: "not_authenticated"),
            MVOidcFixtures.discovery(),
            .init(statusCode: 503, headers: [:], body: Data()),
        ]
        do {
            _ = try await rig.client.getMe()
            XCTFail("expected an error")
        } catch let error as MVError {
            guard case .transport = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(rig.signedOut.all.isEmpty)
        XCTAssertEqual(rig.holder.tokens.accessToken, "access-1")
    }

    /// The app's own 403s carry a JSON detail: the token is fine, so nothing refreshes and nothing
    /// signs out.
    func testTheAppsOwn403LeavesThePersonSignedIn() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.stub = MVOidcFixtures.jsonError(status: 403, detail: "admin_required")
        do {
            _ = try await rig.client.getMe()
            XCTFail("expected an error")
        } catch let error as MVError {
            XCTAssertTrue(error.isForbidden)
            XCTAssertFalse(error.endsSession)
        }
        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, 1)
        XCTAssertTrue(rig.signedOut.all.isEmpty)
    }

    func testADisabledUserIsSignedOutWithoutARefresh() async throws {
        let rig = try makeRig()
        MVStubURLProtocol.stub = MVOidcFixtures.jsonError(status: 403, detail: "user_disabled")
        do {
            _ = try await rig.client.getMe()
            XCTFail("expected an error")
        } catch let error as MVError {
            XCTAssertTrue(error.isDisabled)
        }
        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(rig.signedOut.all.count, 1)
    }

    func testAnExpiredTokenIsRenewedBeforeTheRequestGoesOut() async throws {
        let holder = MVOidcTokenHolder(MVOidcFixtures.tokens(expiresAt: Date().addingTimeInterval(-5)))
        let session = MVStubURLProtocol.makeSession()
        let refresher = MVTokenRefresher(
            holder: holder, client: MVOidcClient(urlSession: session), persist: { _ in })
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", authProvider: { holder.authMode })
        let client = MVApiClient(
            requestFactory: factory, urlSession: session, credentialRefresher: refresher)
        MVStubURLProtocol.queue = [
            MVOidcFixtures.discovery(),
            MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2"),
            MVOidcFixtures.ok(Self.meJSON),
        ]
        _ = try await client.getMe()
        XCTAssertEqual(bearers(), ["Bearer access-2"])
    }

    /// Without a refresher (none, bearer, basic) a JSON 403 no longer signs the user out, and the
    /// proxy's bare 403 still does.
    func testOtherModesKeepTheStatusRules() async throws {
        let signedOut = MVCallLog()
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", authProvider: { .bearer(token: "t") })
        let client = MVApiClient(
            requestFactory: factory, urlSession: MVStubURLProtocol.makeSession(),
            onAuthenticationFailure: { signedOut.record($0.userMessage) })

        MVStubURLProtocol.stub = MVOidcFixtures.jsonError(status: 403, detail: "admin_required")
        _ = try? await client.getMe()
        XCTAssertTrue(signedOut.all.isEmpty)

        MVStubURLProtocol.stub = MVOidcFixtures.proxyForbidden
        _ = try? await client.getMe()
        XCTAssertEqual(signedOut.all.count, 1)
    }
}
