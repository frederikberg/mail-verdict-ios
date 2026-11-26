import XCTest

@testable import MailVerdictKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The access keys screen's logic: what a key is said to be allowed, and that signing one out
/// ends the right sign-in. What a refactor could break silently: a write scope read as no read
/// access, a write limit losing a calendar it cannot name, a sign-out sent for the wrong id or for
/// a key that has none, and the list not following a change made elsewhere.
@MainActor
final class MVAccessKeysStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private let workCalendar = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!
    private let goneCalendar = UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!
    private let signInId = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!

    private func makeStore() -> MVAccessKeysStore {
        let factory = try! MVRequestFactory(
            baseURL: "https://stub.example.com", deviceName: "Test iPhone", authProvider: { .none })
        let client = MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession())
        return MVAccessKeysStore(apiClient: client)
    }

    private func key(
        subject: String, label: String?, access: String, scopes: [String], calendarLimit: [UUID]?,
        signInId: UUID?, revokedAt: String? = nil
    ) -> String {
        let scopesJSON = scopes.map { "\"\($0)\"" }.joined(separator: ",")
        let limitJSON = calendarLimit.map { "[" + $0.map { "\"\($0)\"" }.joined(separator: ",") + "]" } ?? "null"
        return """
            {"subject":"\(subject)","label":\(label.map { "\"\($0)\"" } ?? "null"),
            "user_id":"00000000-0000-0000-0000-0000000000b1","user_display_name":"Owner",
            "access":"\(access)","scopes":[\(scopesJSON)],"calendar_write_ids":\(limitJSON),
            "addressbook_write_ids":null,"created_at":"2026-11-01T10:00:00.123456+00:00",
            "sign_in_id":\(signInId.map { "\"\($0)\"" } ?? "null"),
            "first_seen_at":\(signInId == nil ? "null" : "\"2026-11-02T10:00:00+00:00\""),
            "last_seen_at":\(signInId == nil ? "null" : "\"2026-11-03T10:00:00+00:00\""),
            "revoked_at":\(revokedAt.map { "\"\($0)\"" } ?? "null"),"last_refusal_at":null}
            """
    }

    private func stubKeys(_ keys: [String]) {
        MVStubURLProtocol.stubsByPath["/api/me/access-keys"] = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data("[\(keys.joined(separator: ","))]".utf8))
    }

    private func stubCalendars() {
        let calendar = """
            {"id":"\(workCalendar)","dav_account_id":"00000000-0000-0000-0000-0000000000d1",
            "dav_account_name":"Home","display_name":"Work","color":"#336699","color_override":null,
            "is_visible":true,"is_enabled":true,"read_only":false,"identity_id":null,"intake":"none",
            "supported_components":["VEVENT"],"holds_events":true,"sync_error":null,
            "initial_sync_done":true,"total_count":1,"default_reminder_minutes":null,
            "reminders_enabled":true,"resolved_default_reminder_minutes":null}
            """
        MVStubURLProtocol.stubsByPath["/api/calendars"] = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("[\(calendar)]".utf8))
    }

    func testAScopedKeySaysWhatItMayDoAndNamesOrCountsItsCalendars() async throws {
        stubKeys([
            key(
                subject: "111", label: "Agent", access: "scoped",
                scopes: ["calendar:write", "contacts:read"], calendarLimit: [workCalendar, goneCalendar],
                signInId: signInId),
            key(subject: "222", label: nil, access: "full", scopes: [], calendarLimit: nil, signInId: nil),
        ])
        stubCalendars()
        let store = makeStore()

        await store.load()

        XCTAssertEqual(store.keys.count, 2)
        let scoped = try XCTUnwrap(store.keys.first { $0.subject == "111" })
        XCTAssertEqual(
            scoped.grantLines(calendarNames: store.calendarNames),
            [
                "Calendars: can read and change, only in Work, one calendar not listed here",
                "Contacts: can read",
            ])
        let full = try XCTUnwrap(store.keys.first { $0.subject == "222" })
        XCTAssertEqual(full.access, .full)
        XCTAssertEqual(full.grantLines(), [])
        XCTAssertEqual(full.displayName, "222")
        XCTAssertEqual(full.state, .unused)
    }

    func testSigningOutEndsTheKeysOwnSignInAndReadsTheListAgain() async throws {
        stubKeys([
            key(
                subject: "111", label: "Agent", access: "scoped", scopes: ["calendar:read"],
                calendarLimit: nil, signInId: signInId)
        ])
        let store = makeStore()
        await store.load()
        let revokePath = "/api/me/sign-ins/\(signInId)/revoke"
        MVStubURLProtocol.stubsByPath[revokePath] = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"id":"\(signInId)","kind":"machine","name":null,"revoked_at":"2026-11-04T10:00:00+00:00",
                "current":false}
                """.utf8))
        stubKeys([
            key(
                subject: "111", label: "Agent", access: "scoped", scopes: ["calendar:read"],
                calendarLimit: nil, signInId: signInId, revokedAt: "2026-11-04T10:00:00+00:00")
        ])

        try await store.signOut(store.keys[0])

        let revoke = try XCTUnwrap(MVStubURLProtocol.capturedRequests.first { $0.url?.path == revokePath })
        XCTAssertEqual(revoke.httpMethod, "POST")
        XCTAssertEqual(MVStubURLProtocol.capturedPaths.last, "/api/me/access-keys")
        XCTAssertEqual(store.keys.first?.state, .signedOut)
    }

    func testAKeyThatNeverSignedInCannotBeSignedOutAndNothingIsSent() async throws {
        stubKeys([
            key(
                subject: "111", label: nil, access: "scoped", scopes: ["calendar:read"], calendarLimit: nil,
                signInId: nil)
        ])
        let store = makeStore()
        await store.load()
        let sent = MVStubURLProtocol.capturedRequests.count

        do {
            try await store.signOut(store.keys[0])
            XCTFail("expected notSignedIn")
        } catch let error as MVAccessKeysStoreError {
            XCTAssertEqual(error, .notSignedIn)
        }
        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, sent)
    }

    func testAChangeAnnouncedByTheServerReadsTheListAgain() async throws {
        stubKeys([])
        let store = makeStore()
        await store.load()
        XCTAssertTrue(store.keys.isEmpty)
        stubKeys([
            key(
                subject: "111", label: "New", access: "scoped", scopes: ["contacts:read"], calendarLimit: nil,
                signInId: nil)
        ])

        store.apply([
            LiveEventHub.mapRecord(
                MVSseRecord(id: "1-1", name: "access_key.changed", data: #"{"subject":"111","change":"created"}"#))
        ])

        await waitUntil { store.keys.count == 1 }
    }
}
