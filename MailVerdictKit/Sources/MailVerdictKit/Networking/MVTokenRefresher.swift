import Foundation

/// What a request found out about its credential, as far as the person is concerned.
public enum MVRefreshOutcome: Sendable, Equatable {
    /// The token in use is fresh; send the request again.
    case refreshed
    /// The provider refused the refresh token: the session is over and the person must sign in.
    case rejected
    /// The provider could not be reached or did not answer sensibly. The credential is not known
    /// to be bad, so nothing is signed out.
    case unavailable
}

/// What `MVApiClient` and `MVSseClient` ask when the server refuses their bearer token. A protocol
/// so a client can be built, and tested, without an OIDC provider.
public protocol MVCredentialRefreshing: Sendable {
    /// Renews a token that is expired or about to be, before a request goes out with it.
    func refreshIfNeeded() async
    /// Renews after a request under `accessToken` was refused. Answers `.refreshed` without asking
    /// the provider when the token has already been replaced since — several requests refused
    /// together renew once.
    func refresh(afterRejectionOf accessToken: String?) async -> MVRefreshOutcome
}

/// The token set currently in use, readable from the synchronous closure `MVRequestFactory` takes
/// its credential from.
public final class MVOidcTokenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: MVOidcTokens

    public init(_ tokens: MVOidcTokens) { current = tokens }

    public var tokens: MVOidcTokens {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); defer { lock.unlock() }; current = newValue }
    }

    /// The credential a request factory's `authProvider` returns.
    public var authMode: MVAuthMode { .oidc(tokens) }
}

/// Keeps one sign-in alive: renews the access token before and after it lapses, and stores each
/// new token set the moment it arrives.
///
/// Single-flight: however many requests find the token expired or refused at once, the provider
/// is asked once and all of them take its answer. That matters beyond tidiness — Zitadel rotates
/// refresh tokens, so two simultaneous refreshes with the same one would leave the loser holding
/// a token the winner just retired. The app, the share extension and the Shortcuts intents are
/// separate processes sharing one stored token set, so a refresh first looks at what the store
/// holds (`reload`): a token set another process already renewed is taken as it is instead of
/// spending the refresh token a second time.
public actor MVTokenRefresher: MVCredentialRefreshing {
    private let holder: MVOidcTokenHolder
    private let client: MVOidcClient
    private let persist: @Sendable (MVOidcTokens) -> Void
    private let reload: @Sendable () -> MVOidcTokens?
    private let now: @Sendable () -> Date

    private var metadata: MVOidcProviderMetadata?
    private var inFlight: Task<MVRefreshOutcome, Never>?
    /// The refresh token the provider last refused. Requests that were already in flight when the
    /// session ended all report their own 401; none of them should ask the provider again.
    private var refusedRefreshToken: String?

    /// - Parameter persist: stores a new token set (the Keychain). Called before the new tokens
    ///   are put to use, so a crash between the two cannot lose a rotated refresh token.
    /// - Parameter reload: the token set the store holds right now, `nil` when it holds none.
    public init(
        holder: MVOidcTokenHolder, client: MVOidcClient = MVOidcClient(),
        persist: @escaping @Sendable (MVOidcTokens) -> Void,
        reload: @escaping @Sendable () -> MVOidcTokens? = { nil },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.holder = holder
        self.client = client
        self.persist = persist
        self.reload = reload
        self.now = now
    }

    public func refreshIfNeeded() async {
        let tokens = holder.tokens
        guard tokens.refreshToken != nil, tokens.isExpired(at: now()) else { return }
        _ = await refresh(afterRejectionOf: nil)
    }

    public func refresh(afterRejectionOf accessToken: String?) async -> MVRefreshOutcome {
        if let inFlight { return await inFlight.value }
        let tokens = holder.tokens
        if let accessToken, accessToken != tokens.accessToken { return .refreshed }
        if let refreshToken = tokens.refreshToken, refreshToken == refusedRefreshToken { return .rejected }

        let task = Task { await self.renew() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func renew() async -> MVRefreshOutcome {
        if let stored = reload(), stored != holder.tokens {
            holder.tokens = stored
            if !stored.isExpired(at: now()) { return .refreshed }
        }
        let tokens = holder.tokens
        guard tokens.refreshToken != nil else { return .rejected }
        do {
            let provider: MVOidcProviderMetadata
            if let metadata {
                provider = metadata
            } else {
                provider = try await client.discover(issuer: tokens.issuer)
                metadata = provider
            }
            let renewed = try await client.refresh(tokens, metadata: provider)
            persist(renewed)
            holder.tokens = renewed
            return .refreshed
        } catch let error as MVOidcError where error.isRejection {
            refusedRefreshToken = tokens.refreshToken
            return .rejected
        } catch {
            return .unavailable
        }
    }
}
