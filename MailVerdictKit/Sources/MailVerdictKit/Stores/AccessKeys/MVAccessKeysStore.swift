import Foundation
import Observation

/// The signed-in person's own access keys and signing one out. Creating a key and changing what
/// it may do stay on the web, where an administrator attaches keys.
@Observable
@MainActor
public final class MVAccessKeysStore {
    public enum LoadState {
        case loading
        case loaded
        case failed(Error)
    }

    public private(set) var keys: [AccessKeyResponse] = []
    public private(set) var state: LoadState = .loading
    /// Names of the person's calendars, for a key whose writes are confined to some of them.
    public private(set) var calendarNames: [UUID: String] = [:]

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }

    public func load() async {
        if keys.isEmpty { state = .loading }
        do {
            keys = try await apiClient.listOwnAccessKeys()
            state = .loaded
        } catch {
            state = .failed(error)
            return
        }
        if keys.contains(where: { $0.calendarWriteIds != nil }),
            let calendars = try? await apiClient.listCalendars()
        {
            calendarNames = Dictionary(
                calendars.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Ends the key's sign-in, so every token it holds or mints from then on is refused. Throws
    /// for a key that has never signed in (there is nothing to end) and for a server refusal.
    public func signOut(_ key: AccessKeyResponse) async throws {
        guard key.canSignOut, let signInId = key.signInId else {
            throw MVAccessKeysStoreError.notSignedIn
        }
        try await apiClient.revokeOwnSignIn(id: signInId)
        await load()
    }
}

public enum MVAccessKeysStoreError: Error, Equatable {
    /// The key has not signed in yet, or is signed out already.
    case notSignedIn
}

extension MVAccessKeysStore: LiveEventSubscriber {
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        guard invalidations.contains(where: { $0 == .accessKeysChanged || $0 == .resync }) else { return }
        Task { await self.load() }
    }
}
