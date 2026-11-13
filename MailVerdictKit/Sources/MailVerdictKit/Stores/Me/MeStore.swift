import Foundation
import Observation

/// Who is signed in and whether they are an admin, from `GET /api/me`. Read by whatever decides
/// which screens to offer: until the answer arrives nobody is an admin, so an admin screen never
/// flashes up for a user whose role is still unknown.
@Observable
@MainActor
public final class MeStore {
    public private(set) var me: MeResponse?
    public private(set) var errorMessage: String?

    private let apiClient: MVApiClient
    private var liveSubscriptionToken: MVSubscriptionToken?

    public init(apiClient: MVApiClient) {
        self.apiClient = apiClient
    }

    public var isAdmin: Bool { me?.isAdmin ?? false }

    /// The settings categories to list for this user.
    public var settingsCategories: [MVSettingsCategory] { MVSettingsCategory.available(isAdmin: isAdmin) }

    public func canOpen(_ category: MVSettingsCategory) -> Bool { isAdmin || !category.isAdminOnly }

    /// Keeps the last answer when a reload fails, so a dropped connection does not take the admin
    /// screens away from an admin mid-use.
    public func load() async {
        do {
            me = try await apiClient.getMe()
            errorMessage = nil
        } catch {
            errorMessage = error.mvUserMessage
        }
    }

    /// Forgets who was signed in, on sign-out.
    public func clear() {
        me = nil
        errorMessage = nil
    }

    // MARK: - Live updates

    public func subscribeToLive(_ hub: LiveEventHub) {
        guard liveSubscriptionToken == nil else { return }
        liveSubscriptionToken = hub.subscribe(self)
    }

    public func unsubscribeFromLive(_ hub: LiveEventHub) {
        guard let token = liveSubscriptionToken else { return }
        hub.unsubscribe(token)
        liveSubscriptionToken = nil
    }
}

extension MeStore: LiveEventSubscriber {
    /// A role change announces nothing on the stream, so the app also loads on connect and on
    /// returning to the foreground; a resync or a settings change reloads it here as well.
    public func apply(_ invalidations: [MVLiveInvalidation]) {
        let shouldReload = invalidations.contains {
            switch $0 {
            case .resync, .settingsChanged: return true
            default: return false
            }
        }
        guard shouldReload else { return }
        Task { await self.load() }
    }
}
