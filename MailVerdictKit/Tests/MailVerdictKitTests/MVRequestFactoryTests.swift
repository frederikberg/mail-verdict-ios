import XCTest
@testable import MailVerdictKit

/// These cover the rules that are easy to break and silent when broken — the scheme guard, the
/// trailing-slash join, and reading the token at send time rather than at construction. Straight
/// URL concatenation is not tested; it would pass without proving anything.
final class MVRequestFactoryTests: XCTestCase {

    func testRejectsNonHttpScheme() {
        XCTAssertThrowsError(
            try MVRequestFactory(baseURL: "ftp://example.com", deviceName: "Test iPhone", authProvider: { .none })
        ) { error in
            XCTAssertEqual(
                error as? MVRequestFactory.ConfigurationError,
                .unsupportedScheme("ftp")
            )
        }
    }

    func testRejectsEmptyBaseURL() {
        XCTAssertThrowsError(
            try MVRequestFactory(baseURL: "   ", deviceName: "Test iPhone", authProvider: { .none })
        ) { error in
            XCTAssertEqual(error as? MVRequestFactory.ConfigurationError, .emptyBaseURL)
        }
    }

    func testTrailingSlashDoesNotDoubleUp() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com/",
            deviceName: "Test iPhone", authProvider: { .none }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.url?.absoluteString, "https://mail.example.com/api/health")
    }

    /// The credential is read per request, so entering one in the connection screen takes effect
    /// immediately rather than on the next launch.
    func testTokenIsReadAtSendTimeNotConstructionTime() throws {
        let box = TokensBox()
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com",
            deviceName: "Test iPhone", authProvider: { box.value }
        )

        let before = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(before.value(forHTTPHeaderField: "Authorization"))

        box.value = MVOidcFixtures.tokens(access: "jwt-value")
        let after = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(after.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-value")
    }

    func testEmptyAccessTokenSendsNoAuthorizationHeader() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com",
            deviceName: "Test iPhone", authProvider: { MVOidcFixtures.tokens(access: "", refresh: "r") }
        )
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testEveryRequestCarriesTheDeviceName() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", deviceName: "Frederik's iPhone", authProvider: { .none })
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Name"), "Frederik's iPhone")
    }

    func testDeviceNameIsCutToSixtyFourCharactersAndStaysOneLine() {
        XCTAssertEqual(MVDeviceName.header(for: String(repeating: "é", count: 80)).count, 64)
        XCTAssertEqual(MVDeviceName.header(for: "  Work\nphone  "), "Work phone")
        XCTAssertEqual(MVDeviceName.header(for: " \n "), "iPhone")
    }

    /// `URLComponents` leaves a literal `+` in a query value alone — it is a legal query
    /// character per RFC 3986 — but a server commonly decodes the query as
    /// `application/x-www-form-urlencoded`, where `+` means space. A folder name or search term
    /// containing `+` must round-trip as itself, not as a space.
    func testQueryValueEscapesLiteralPlusRatherThanLeavingItAsASpace() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", deviceName: "Test iPhone", authProvider: { .none }
        )
        let request = try factory.makeRequest(
            path: "/api/search",
            query: [URLQueryItem(name: "q", value: "a+b")]
        )
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.contains("q=a%2Bb"), raw)
        XCTAssertFalse(raw.contains("q=a+b"), raw)
    }

    /// Joins `baseURL.path` and `path` via `percentEncodedPath`, which passes an already-encoded
    /// path through untouched — the regression this guards is a return to
    /// `appendingPathComponent`, which would re-encode a pre-encoded segment (`%2F` becoming
    /// `%252F`).
    func testPreEncodedPathSegmentSurvivesWithoutBeingReEncoded() throws {
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", deviceName: "Test iPhone", authProvider: { .none }
        )
        let request = try factory.makeRequest(path: "/api/folders/a%2Fb")
        let raw = request.url?.absoluteString ?? ""
        XCTAssertTrue(raw.hasSuffix("/api/folders/a%2Fb"), raw)
        XCTAssertFalse(raw.contains("%25"), raw)
    }

    func testOidcSendsTheAccessTokenAsBearer() throws {
        let tokens = MVOidcTokens(accessToken: "access", refreshToken: "refresh", issuer: "https://i", clientId: "c")
        let factory = try MVRequestFactory(
            baseURL: "https://mail.example.com", deviceName: "Test iPhone", authProvider: { tokens })
        let request = try factory.makeRequest(path: "/api/health")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
        XCTAssertEqual(request.mvBearerToken, "access")
    }

    func testTokenSetSurvivesTheKeychainsJsonEncoding() throws {
        let tokens = MVOidcTokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_700_000_000),
            issuer: "https://i", clientId: "c")
        let stored = try JSONEncoder().encode(tokens)
        XCTAssertEqual(MVStoredCredential.decode(stored), .current(tokens))
    }

    /// What a phone updated from an earlier version still holds: the OIDC sign-in is carried over,
    /// everything else is dropped so the app asks for a sign-in. The literals are the JSON the
    /// earlier enum encoded.
    func testStoredCredentialsOfEarlierVersionsAreCarriedOverOrDropped() throws {
        let oidc = #"{"oidc":{"_0":{"accessToken":"a","refreshToken":"r","issuer":"https://i","clientId":"c"}}}"#
        XCTAssertEqual(
            MVStoredCredential.decode(Data(oidc.utf8)),
            .migrated(MVOidcTokens(accessToken: "a", refreshToken: "r", issuer: "https://i", clientId: "c")))

        let dropped = [
            #"{"bearer":{"token":"a-key-that-lives-a-hundred-years"}}"#,
            #"{"basic":{"username":"u","password":"p"}}"#,
            #"{"none":{}}"#,
            #"{"oidc":{"_0":{"accessToken":"","issuer":"https://i","clientId":"c"}}}"#,
            "not json",
            "",
        ]
        for json in dropped {
            XCTAssertEqual(MVStoredCredential.decode(Data(json.utf8)), .unusable, json)
        }
    }

    func testTokenExpiryHonoursTheSkew() {
        let now = Date(timeIntervalSince1970: 1000)
        func tokens(_ expiresAt: Date?) -> MVOidcTokens {
            MVOidcTokens(accessToken: "a", expiresAt: expiresAt, issuer: "i", clientId: "c")
        }
        XCTAssertTrue(tokens(now.addingTimeInterval(59)).isExpired(at: now))
        XCTAssertFalse(tokens(now.addingTimeInterval(61)).isExpired(at: now))
        XCTAssertFalse(tokens(nil).isExpired(at: now))
    }
}

/// A `var` captured by an escaping sendable closure and mutated afterwards is a data race the
/// compiler cannot rule out, even where the test is single-threaded. A reference box makes the
/// sharing explicit instead of asserting it away.
private final class TokensBox: @unchecked Sendable {
    var value: MVOidcTokens?
}
