import Foundation
import MailVerdictKit

/// What signing out tells the server while the phone still holds its credential: drop this
/// device's push registration, then end this sign-in. Each step is best effort and the whole run
/// is bounded, so a phone without a network still signs out; whatever the server did not hear it
/// forgets on its own once the sign-in's token expires or is revoked.
public struct ServerSignOut: Sendable {
    public var deleteSubscription: @Sendable (UUID) async throws -> Void
    public var currentSignInId: @Sendable () async throws -> UUID?
    public var revokeSignIn: @Sendable (UUID) async throws -> Void

    public init(
        deleteSubscription: @escaping @Sendable (UUID) async throws -> Void,
        currentSignInId: @escaping @Sendable () async throws -> UUID?,
        revokeSignIn: @escaping @Sendable (UUID) async throws -> Void
    ) {
        self.deleteSubscription = deleteSubscription
        self.currentSignInId = currentSignInId
        self.revokeSignIn = revokeSignIn
    }

    public init(api: MVApiClient) {
        self.init(
            deleteSubscription: { try await api.deletePushSubscription(id: $0) },
            currentSignInId: { try await api.listOwnSignIns().first { $0.current }?.id },
            revokeSignIn: { try await api.revokeOwnSignIn(id: $0) })
    }

    /// Runs both steps in order — the push row first, since revoking the sign-in makes every
    /// later request refuse — and gives up after `timeout` seconds.
    public func run(subscriptionId: UUID?, timeout: TimeInterval) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await steps(subscriptionId: subscriptionId) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func steps(subscriptionId: UUID?) async {
        if let subscriptionId { try? await deleteSubscription(subscriptionId) }
        if let id = try? await currentSignInId() { try? await revokeSignIn(id) }
    }
}

/// The phone's own copy of the push registration: the content key the notification extension
/// opens alerts with, and the record of the registration. With both gone a late push is
/// unreadable and the app registers afresh on the next sign-in.
public enum PushLocalSignOut {
    public static func clear(
        serverOrigin: String, records: PushRecordStore, installations: some PushInstallationStoring
    ) {
        try? installations.delete(serverOrigin: serverOrigin)
        records.remove(serverOrigin: serverOrigin)
    }
}
