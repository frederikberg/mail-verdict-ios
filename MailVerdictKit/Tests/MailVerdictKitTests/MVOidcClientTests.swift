import XCTest

@testable import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class MVOidcClientTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient(now: @escaping @Sendable () -> Date = { Date() }) -> MVOidcClient {
        MVOidcClient(urlSession: MVStubURLProtocol.makeSession(), now: now)
    }

    private func metadata() async throws -> MVOidcProviderMetadata {
        MVStubURLProtocol.stub = MVOidcFixtures.discovery()
        return try await makeClient().discover(issuer: MVOidcFixtures.issuer)
    }

    // MARK: Discovery

    func testDiscoveryReadsTheEndpoints() async throws {
        let found = try await metadata()
        XCTAssertEqual(found.authorizationEndpoint.absoluteString, "https://login.example.com/oauth/v2/authorize")
        XCTAssertEqual(found.tokenEndpoint.absoluteString, "https://login.example.com/oauth/v2/token")
        XCTAssertEqual(
            MVStubURLProtocol.capturedRequest?.url?.absoluteString,
            "https://login.example.com/.well-known/openid-configuration")
    }

    func testDiscoveryRefusesADocumentForAnotherIssuer() async {
        MVStubURLProtocol.stub = MVOidcFixtures.discovery(issuer: "https://evil.example.net")
        do {
            _ = try await makeClient().discover(issuer: MVOidcFixtures.issuer)
            XCTFail("expected a refusal")
        } catch let error as MVOidcError {
            guard case .discoveryFailed = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testDiscoveryOutageIsUnavailableNotRejected() async {
        MVStubURLProtocol.stub = .init(statusCode: 503, headers: [:], body: Data())
        do {
            _ = try await makeClient().discover(issuer: MVOidcFixtures.issuer)
            XCTFail("expected an error")
        } catch let error as MVOidcError {
            XCTAssertFalse(error.isRejection)
        } catch { XCTFail("\(error)") }
    }

    // MARK: Authorization request and callback

    func testAuthorizationURLCarriesTheCodeFlowParameters() async throws {
        let found = try await metadata()
        let pkce = MVPkce.Pair(verifier: "v", challenge: "chal")
        let url = try makeClient().authorizationURL(
            config: MVOidcFixtures.config, metadata: found, pkce: pkce, state: "st")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "login.example.com")
        XCTAssertEqual(value("response_type"), "code")
        XCTAssertEqual(value("client_id"), MVOidcFixtures.clientId)
        XCTAssertEqual(value("redirect_uri"), "mailverdict://auth/callback")
        XCTAssertEqual(value("scope"), "openid profile email offline_access")
        XCTAssertEqual(value("state"), "st")
        XCTAssertEqual(value("code_challenge"), "chal")
        XCTAssertEqual(value("code_challenge_method"), "S256")
    }

    func testAuthorizationURLNeedsAClientId() async throws {
        let found = try await metadata()
        let config = AuthConfigResponse(issuer: "https://login.example.com", clientId: nil, scopes: "", redirectUri: "")
        XCTAssertThrowsError(
            try makeClient().authorizationURL(
                config: config, metadata: found, pkce: MVPkce.makePair(), state: "s")
        ) { XCTAssertEqual($0 as? MVOidcError, .signInUnavailable) }
    }

    func testCallbackYieldsTheCodeOnlyForTheExpectedState() throws {
        let client = makeClient()
        let good = URL(string: "mailverdict://auth/callback?code=abc%2B1&state=st")!
        XCTAssertEqual(try client.parseCallback(good, expectedState: "st"), "abc+1")

        let wrongState = URL(string: "mailverdict://auth/callback?code=abc&state=other")!
        XCTAssertThrowsError(try client.parseCallback(wrongState, expectedState: "st"))
        let noCode = URL(string: "mailverdict://auth/callback?state=st")!
        XCTAssertThrowsError(try client.parseCallback(noCode, expectedState: "st"))
        let denied = URL(string: "mailverdict://auth/callback?error=access_denied&state=st")!
        XCTAssertThrowsError(try client.parseCallback(denied, expectedState: "st")) {
            XCTAssertEqual($0 as? MVOidcError, .callbackRejected("access_denied"))
        }
    }

    // MARK: Token requests

    func testCodeExchangeSendsTheVerifierAndStoresTheTokenSet() async throws {
        let found = try await metadata()
        let now = Date(timeIntervalSince1970: 1_000_000)
        MVStubURLProtocol.stub = MVOidcFixtures.tokenAnswer(access: "a", refresh: "r", expiresIn: 600)
        let tokens = try await makeClient(now: { now }).exchangeCode(
            "the code", pkce: MVPkce.Pair(verifier: "ver+ifier", challenge: "c"), config: MVOidcFixtures.config,
            metadata: found)

        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertEqual(tokens.refreshToken, "r")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(600))
        XCTAssertEqual(tokens.issuer, MVOidcFixtures.issuer)
        XCTAssertEqual(tokens.clientId, MVOidcFixtures.clientId)

        let request = try XCTUnwrap(MVStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = MVOidcFixtures.requestBody(request)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=the%20code"))
        XCTAssertTrue(body.contains("code_verifier=ver%2Bifier"))
        XCTAssertTrue(body.contains("redirect_uri=mailverdict%3A%2F%2Fauth%2Fcallback"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "a public client sends no secret")
    }

    func testRefreshReplacesARotatedRefreshToken() async throws {
        let found = try await metadata()
        MVStubURLProtocol.stub = MVOidcFixtures.tokenAnswer(access: "a2", refresh: "r2")
        let renewed = try await makeClient().refresh(MVOidcFixtures.tokens(), metadata: found)
        XCTAssertEqual(renewed.accessToken, "a2")
        XCTAssertEqual(renewed.refreshToken, "r2")
        let body = MVOidcFixtures.requestBody(MVStubURLProtocol.capturedRequest)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=refresh-1"))
    }

    func testRefreshKeepsTheOldRefreshTokenWhenNoneIsReturned() async throws {
        let found = try await metadata()
        MVStubURLProtocol.stub = MVOidcFixtures.tokenAnswer(access: "a2", refresh: nil)
        let renewed = try await makeClient().refresh(MVOidcFixtures.tokens(), metadata: found)
        XCTAssertEqual(renewed.refreshToken, "refresh-1")
    }

    func testAGrantRefusalIsARejectionAndAnOutageIsNot() async throws {
        let found = try await metadata()
        for status in [400, 401] {
            MVStubURLProtocol.stub = MVOidcFixtures.tokenRefusal(status: status)
            do {
                _ = try await makeClient().refresh(MVOidcFixtures.tokens(), metadata: found)
                XCTFail("expected a refusal")
            } catch let error as MVOidcError {
                XCTAssertTrue(error.isRejection, "HTTP \(status)")
            }
        }
        for status in [429, 500, 503] {
            MVStubURLProtocol.stub = .init(statusCode: status, headers: [:], body: Data())
            do {
                _ = try await makeClient().refresh(MVOidcFixtures.tokens(), metadata: found)
                XCTFail("expected an error")
            } catch let error as MVOidcError {
                XCTAssertFalse(error.isRejection, "HTTP \(status)")
            }
        }
        MVStubURLProtocol.stub = .init(statusCode: 0, headers: [:], body: Data(), failure: .notConnectedToInternet)
        do {
            _ = try await makeClient().refresh(MVOidcFixtures.tokens(), metadata: found)
            XCTFail("expected an error")
        } catch let error as MVOidcError {
            XCTAssertFalse(error.isRejection)
        }
    }

    func testFormEncodingEscapesEverythingButUnreserved() {
        XCTAssertEqual(MVOidcClient.formEncoded([("a b", "c+d=e&f"), ("k", "A-._~z")]), "a%20b=c%2Bd%3De%26f&k=A-._~z")
    }
}
