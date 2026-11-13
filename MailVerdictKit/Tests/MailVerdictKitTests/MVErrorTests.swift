import XCTest
@testable import MailVerdictKit

final class MVErrorTests: XCTestCase {

    func testErrorPrefersServerDetailOverStatusLine() {
        let body = Data(#"{"detail":"account not found"}"#.utf8)
        XCTAssertEqual(MVError.from(statusCode: 404, body: body).userMessage, "account not found")
    }

    func testErrorFallsBackToStatusLineOnNonJsonBody() {
        let error = MVError.from(statusCode: 502, body: Data("<html>".utf8))
        XCTAssertTrue(error.userMessage.hasPrefix("HTTP 502:"))
    }

    /// `.decoding`'s own associated text is a `DecodingError`'s raw, verbose description, built
    /// from `"\(error)"` at every call site — never what a screen shows.
    func testDecodingErrorNeverShowsTheRawDescriptionItCarries() {
        let raw = #"Swift.DecodingError.typeMismatch(Swift.String, ...)"#
        XCTAssertFalse(MVError.decoding(raw).userMessage.contains(raw))
    }

    /// This is the one property every call site actually branches on — whether the credential,
    /// not the request, was the problem — so a future status code added here has to be
    /// classified correctly or a rejected token silently reads as an ordinary failure.
    func testOnlyCredentialRefusalsAreClassifiedAsAuthFailures() {
        XCTAssertTrue(MVError.detail("expired", statusCode: 401).isAuthenticationFailure)
        XCTAssertTrue(MVError.http(statusCode: 401, reason: "Unauthorized").isAuthenticationFailure)
        // The login proxy's refusal of a token is a bare, non-JSON 403.
        XCTAssertTrue(MVError.http(statusCode: 403, reason: "Forbidden").isAuthenticationFailure)
        // The app's own 403 carries a JSON detail and leaves the user signed in.
        XCTAssertFalse(MVError.detail("admin_required", statusCode: 403).isAuthenticationFailure)
        XCTAssertFalse(MVError.detail("nope", statusCode: 404).isAuthenticationFailure)
        XCTAssertFalse(MVError.transport("offline").isAuthenticationFailure)
        XCTAssertFalse(MVError.decoding("bad json").isAuthenticationFailure)
    }

    func testForbiddenAndDisabledAreTheAppsOwnRefusals() {
        let forbidden = MVError.detail("admin_required", statusCode: 403)
        XCTAssertTrue(forbidden.isForbidden)
        XCTAssertFalse(forbidden.isDisabled)
        XCTAssertFalse(forbidden.endsSession)

        let disabled = MVError.detail("user_disabled", statusCode: 403)
        XCTAssertTrue(disabled.isForbidden)
        XCTAssertTrue(disabled.isDisabled)
        XCTAssertTrue(disabled.endsSession)

        XCTAssertFalse(MVError.http(statusCode: 403, reason: "Forbidden").isForbidden)
        XCTAssertFalse(MVError.detail("user_disabled", statusCode: 401).isDisabled)
    }

    func testAnErrorBodyIsAppLevelOnlyWhenItIsJsonWithADetail() {
        let json = MVError.from(statusCode: 403, body: Data(#"{"detail":"user_disabled"}"#.utf8))
        XCTAssertTrue(json.isDisabled)
        let proxy = MVError.from(statusCode: 403, body: Data("Forbidden".utf8))
        XCTAssertTrue(proxy.isAuthenticationFailure)
    }
}
