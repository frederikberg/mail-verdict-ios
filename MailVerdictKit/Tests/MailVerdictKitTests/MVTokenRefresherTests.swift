import XCTest

@testable import MailVerdictKit

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class MVTokenRefresherTests: XCTestCase {

    override func tearDown() {
        MVStubURLProtocol.reset()
        super.tearDown()
    }

    private struct Rig {
        let refresher: MVTokenRefresher
        let holder: MVOidcTokenHolder
        let persisted: MVCallLog
    }

    private func makeRig(
        tokens: MVOidcTokens = MVOidcFixtures.tokens(), now: @escaping @Sendable () -> Date = { Date() }
    ) -> Rig {
        let holder = MVOidcTokenHolder(tokens)
        let persisted = MVCallLog()
        let refresher = MVTokenRefresher(
            holder: holder, client: MVOidcClient(urlSession: MVStubURLProtocol.makeSession()),
            persist: { persisted.record($0.accessToken + "/" + ($0.refreshToken ?? "-")) }, now: now)
        return Rig(refresher: refresher, holder: holder, persisted: persisted)
    }

    private func tokenRequests() -> Int {
        MVStubURLProtocol.capturedPaths.filter { $0 == "/oauth/v2/token" }.count
    }

    func testRefreshStoresTheRotatedTokensBeforeUsingThem() async {
        MVStubURLProtocol.stubsByPath = [
            "/.well-known/openid-configuration": MVOidcFixtures.discovery(),
            "/oauth/v2/token": MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2"),
        ]
        let rig = makeRig()
        let outcome = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(rig.holder.tokens.accessToken, "access-2")
        XCTAssertEqual(rig.holder.tokens.refreshToken, "refresh-2")
        XCTAssertEqual(rig.persisted.all, ["access-2/refresh-2"])
    }

    /// Zitadel retires a refresh token the moment it is exchanged, so twenty requests refused
    /// together must produce one exchange, not twenty.
    func testConcurrentRefusalsRefreshOnce() async {
        var slowToken = MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2")
        slowToken.delay = 0.3
        MVStubURLProtocol.stubsByPath = [
            "/.well-known/openid-configuration": MVOidcFixtures.discovery(),
            "/oauth/v2/token": slowToken,
        ]
        let rig = makeRig()
        let outcomes = await withTaskGroup(of: MVRefreshOutcome.self) { group in
            for _ in 0..<20 { group.addTask { await rig.refresher.refresh(afterRejectionOf: "access-1") } }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(outcomes, Array(repeating: .refreshed, count: 20))
        XCTAssertEqual(tokenRequests(), 1)
        XCTAssertEqual(rig.persisted.all.count, 1)
    }

    func testARefusalOfAnAlreadyReplacedTokenAsksNobody() async {
        let rig = makeRig(tokens: MVOidcFixtures.tokens(access: "access-2"))
        let outcome = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertTrue(MVStubURLProtocol.capturedRequests.isEmpty)
    }

    func testARefusedRefreshTokenEndsTheSessionAndIsNotAskedAgain() async {
        MVStubURLProtocol.stubsByPath = [
            "/.well-known/openid-configuration": MVOidcFixtures.discovery(),
            "/oauth/v2/token": MVOidcFixtures.tokenRefusal(),
        ]
        let rig = makeRig()
        let first = await rig.refresher.refresh(afterRejectionOf: "access-1")
        let second = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(first, .rejected)
        XCTAssertEqual(second, .rejected)
        XCTAssertEqual(tokenRequests(), 1)
        XCTAssertTrue(rig.persisted.all.isEmpty)
        XCTAssertEqual(rig.holder.tokens.accessToken, "access-1")
    }

    func testAnOutageKeepsTheSessionAndTriesAgainNextTime() async {
        MVStubURLProtocol.stubsByPath = [
            "/.well-known/openid-configuration": MVOidcFixtures.discovery(),
            "/oauth/v2/token": .init(statusCode: 503, headers: [:], body: Data()),
        ]
        let rig = makeRig()
        let first = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(first, .unavailable)

        MVStubURLProtocol.stubsByPath["/oauth/v2/token"] = MVOidcFixtures.tokenAnswer(
            access: "access-2", refresh: "refresh-2")
        let second = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(second, .refreshed)
        XCTAssertEqual(tokenRequests(), 2)
    }

    func testNoRefreshTokenMeansTheSessionEndsWithTheAccessToken() async {
        let rig = makeRig(tokens: MVOidcFixtures.tokens(refresh: nil))
        let outcome = await rig.refresher.refresh(afterRejectionOf: "access-1")
        XCTAssertEqual(outcome, .rejected)
        XCTAssertTrue(MVStubURLProtocol.capturedRequests.isEmpty)
    }

    func testRefreshIfNeededRenewsOnlyAnExpiringToken() async {
        let now = Date(timeIntervalSince1970: 2_000_000)
        MVStubURLProtocol.stubsByPath = [
            "/.well-known/openid-configuration": MVOidcFixtures.discovery(),
            "/oauth/v2/token": MVOidcFixtures.tokenAnswer(access: "access-2", refresh: "refresh-2"),
        ]
        let fresh = makeRig(
            tokens: MVOidcFixtures.tokens(expiresAt: now.addingTimeInterval(600)), now: { now })
        await fresh.refresher.refreshIfNeeded()
        XCTAssertEqual(fresh.holder.tokens.accessToken, "access-1")
        XCTAssertEqual(tokenRequests(), 0)

        let stale = makeRig(
            tokens: MVOidcFixtures.tokens(expiresAt: now.addingTimeInterval(30)), now: { now })
        await stale.refresher.refreshIfNeeded()
        XCTAssertEqual(stale.holder.tokens.accessToken, "access-2")

        let unstated = makeRig(tokens: MVOidcFixtures.tokens(expiresAt: nil), now: { now })
        await unstated.refresher.refreshIfNeeded()
        XCTAssertEqual(unstated.holder.tokens.accessToken, "access-1")
    }
}
