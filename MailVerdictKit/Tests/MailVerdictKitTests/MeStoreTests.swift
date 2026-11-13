import XCTest

@testable import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@MainActor
final class MeStoreTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeStore() -> MeStore {
        let factory = try! MVRequestFactory(baseURL: "https://stub.example.com", authProvider: { .none })
        return MeStore(apiClient: MVApiClient(requestFactory: factory, urlSession: MVStubURLProtocol.makeSession()))
    }

    private func me(role: String) -> String {
        """
        {"user_id":"00000000-0000-0000-0000-000000000002","email":"a@example.com","display_name":"A",
        "role":"\(role)","disabled":false}
        """
    }

    func testNobodyIsAnAdminUntilTheServerSaysSo() {
        let store = makeStore()
        XCTAssertFalse(store.isAdmin)
        XCTAssertEqual(store.settingsCategories, [.outbox, .mail])
    }

    func testAnAdminSeesEveryCategory() async {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "admin"))
        let store = makeStore()
        await store.load()
        XCTAssertTrue(store.isAdmin)
        XCTAssertEqual(store.settingsCategories, MVSettingsCategory.allCases)
        XCTAssertTrue(store.canOpen(.pipeline))
    }

    func testAUserSeesOnlyTheirOwnCategories() async {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "user"))
        let store = makeStore()
        await store.load()
        XCTAssertFalse(store.isAdmin)
        XCTAssertEqual(store.settingsCategories, [.outbox, .mail])
        XCTAssertFalse(store.canOpen(.ai))
        XCTAssertTrue(store.canOpen(.mail))
    }

    func testAFailedReloadKeepsTheLastAnswer() async {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "admin"))
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = .init(statusCode: 0, headers: [:], body: Data(), failure: .notConnectedToInternet)
        await store.load()
        XCTAssertTrue(store.isAdmin)
        XCTAssertNotNil(store.errorMessage)
    }

    func testClearForgetsTheUser() async {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "admin"))
        let store = makeStore()
        await store.load()
        store.clear()
        XCTAssertNil(store.me)
        XCTAssertFalse(store.isAdmin)
    }

    func testResyncAndSettingsChangesReload() async throws {
        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "user"))
        let store = makeStore()
        await store.load()

        MVStubURLProtocol.stub = MVOidcFixtures.ok(me(role: "admin"))
        store.apply([.settingsChanged(category: nil)])
        for _ in 0..<50 where !store.isAdmin { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(store.isAdmin)

        let before = MVStubURLProtocol.capturedRequests.count
        store.apply([.alertsChanged])
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(MVStubURLProtocol.capturedRequests.count, before, "an unrelated event does not reload")
    }
}
