import XCTest

@testable import Push

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

private struct Offline: Error {}

final class ServerSignOutTests: XCTestCase {
    private let subscription = UUID()
    private let signIn = UUID()

    private func signOut(
        calls: Calls, deleteFails: Bool = false, current: UUID?? = nil
    ) -> ServerSignOut {
        let currentId = current ?? .some(signIn)
        let subscription = subscription
        let signIn = signIn
        return ServerSignOut(
            deleteSubscription: { id in
                calls.add("delete \(id == subscription)")
                if deleteFails { throw Offline() }
            },
            currentSignInId: { currentId },
            revokeSignIn: { id in calls.add("revoke \(id == signIn)") })
    }

    /// The push row goes before the sign-in, because revoking the sign-in refuses every later request.
    func testThePushRowIsDeletedBeforeTheSignInIsRevoked() async {
        let calls = Calls()
        await signOut(calls: calls).run(subscriptionId: subscription, timeout: 5)
        XCTAssertEqual(calls.all, ["delete true", "revoke true"])
    }

    func testAFailedPushDeleteDoesNotKeepTheSignInFromEnding() async {
        let calls = Calls()
        await signOut(calls: calls, deleteFails: true).run(subscriptionId: subscription, timeout: 5)
        XCTAssertEqual(calls.all, ["delete true", "revoke true"])
    }

    func testADeviceWithoutARegistrationOrACurrentSignInTouchesNothing() async {
        let calls = Calls()
        await signOut(calls: calls, current: .some(nil)).run(subscriptionId: nil, timeout: 5)
        XCTAssertEqual(calls.all, [])
    }

    /// Offline, a request can hang until the system gives up; sign-out must not wait for it.
    func testAHangingServerDoesNotHoldSignOutBeyondTheTimeout() async {
        let hanging = ServerSignOut(
            deleteSubscription: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) },
            currentSignInId: { nil },
            revokeSignIn: { _ in })
        let started = Date()
        await hanging.run(subscriptionId: subscription, timeout: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testTheRecordIsForgottenPerServer() {
        let suite = UserDefaults(suiteName: "ServerSignOutTests-\(UUID())")!
        let records = PushRecordStore(defaults: suite)
        records.save(PushRegistrationRecord(isEnabled: true, subscriptionId: subscription), serverOrigin: "https://a")
        records.save(PushRegistrationRecord(isEnabled: true), serverOrigin: "https://b")
        records.remove(serverOrigin: "https://a")
        XCTAssertNil(records.load(serverOrigin: "https://a"))
        XCTAssertNotNil(records.load(serverOrigin: "https://b"))
    }
}
