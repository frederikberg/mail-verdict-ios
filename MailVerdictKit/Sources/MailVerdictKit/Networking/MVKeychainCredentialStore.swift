#if canImport(Security)
    import Foundation
    import Security

    /// Where the backend's credential lives: the token set of a Zitadel sign-in, encoded as JSON
    /// in one Keychain item. A pasted key, a basic-auth pair or "no credential" — what earlier
    /// versions could store — is never read: the item is removed and the app asks for a sign-in.
    ///
    /// The Keychain is the only place on the device holding a secret; everything else the app
    /// remembers (the backend URL) is an ordinary preference and lives in `UserDefaults`. The URL
    /// is also published here, in the same access group, because the share extension cannot see
    /// the app's `UserDefaults`: the app writes it, the extension only reads.
    ///
    /// Guarded by `canImport(Security)` because the package also builds on Linux, where one
    /// unguarded import would drag the whole test suite onto a metered runner.
    public struct MVKeychainCredentialStore: Sendable {

        #if DEBUG
            /// Fixture mode's credential, held in memory because the Keychain is not always available.
            ///
            /// A simulator build made with `CODE_SIGNING_ALLOWED=NO` has no keychain-access-group
            /// entitlement, and `SecItemAdd` refuses with `errSecMissingEntitlement`. A signed build
            /// — every build that reaches a device — is unaffected, so this exists only so a Mac
            /// workflow run can get past the connection gate.
            ///
            /// Deliberately not a general fallback: it is consulted only when fixture mode asked for
            /// it, so a real build can never silently keep a credential outside the Keychain.
            nonisolated(unsafe) private static var fixtureCredential: MVOidcTokens?
            private static let fixtureLock = NSLock()
        #endif

        /// The app's bundle identifier, which names the Keychain service and the access group. A
        /// constant rather than `Bundle.main.bundleIdentifier` because the share extension reads
        /// the same items under its own bundle identifier.
        public static let appBundleIdentifier = "com.frederikberg.mailverdict"

        private let service: String
        private let credentialAccount = "backend-credential"
        private let backendURLAccount = "backend-url"

        public init(service: String = MVKeychainCredentialStore.appBundleIdentifier) {
            self.service = service
        }

        private func baseQuery(account: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                // This app's own group, explicit rather than left to default — the entitlements list
                // a second group now (the one shared with the push extension), and an unspecified
                // access group is no longer guaranteed to resolve to this one. It is the same literal
                // an existing item already carries (it was the only group before the split), so
                // pinning it does not strand anything already written. The share extension holds this
                // group too, which is how it reads the credential without a second copy.
                kSecAttrAccessGroup as String: "\(Self.teamId).\(service)",
                // Explicit, not inherited. This is a personal device credential for one backend and
                // has no business syncing to other hardware through iCloud Keychain.
                kSecAttrSynchronizable as String: false,
            ]
        }

        /// The literal team id `$(AppIdentifierPrefix)` resolves to at build time — a Keychain query
        /// needs the resolved string, never the build variable.
        private static let teamId = "CSHG4AV9YH"

        /// The sign-in's token set, `nil` when signed out. An item an earlier version wrote in
        /// another shape is dropped here, so a phone that still carries an old pasted key lands
        /// on the sign-in screen rather than keeping a credential nothing should send; an old
        /// OIDC sign-in is carried over as it is.
        public func read() -> MVOidcTokens? {
            #if DEBUG
                if MVFixtureLaunch.isEnabled() {
                    Self.fixtureLock.lock()
                    defer { Self.fixtureLock.unlock() }
                    if let tokens = Self.fixtureCredential { return tokens }
                }
            #endif
            guard let data = readItem(account: credentialAccount) else { return nil }
            switch MVStoredCredential.decode(data) {
            case .current(let tokens):
                return tokens
            case .migrated(let tokens):
                if let rewritten = try? JSONEncoder().encode(tokens) {
                    _ = writeItem(rewritten, account: credentialAccount)
                }
                return tokens
            case .unusable:
                removeItem(account: credentialAccount)
                return nil
            }
        }

        /// Writing `nil` removes the item.
        @discardableResult
        public func write(_ tokens: MVOidcTokens?) -> Bool {
            guard let tokens, tokens.isUsable, let data = try? JSONEncoder().encode(tokens) else {
                removeItem(account: credentialAccount)
                return true
            }

            let status = writeItem(data, account: credentialAccount)
            #if DEBUG
                if status != errSecSuccess, MVFixtureLaunch.isEnabled() {
                    Self.fixtureLock.lock()
                    Self.fixtureCredential = tokens
                    Self.fixtureLock.unlock()
                    return true
                }
            #endif
            return status == errSecSuccess
        }

        /// The backend address the app is signed in to, as the app last published it. `nil` when
        /// the app has not connected since the share extension was added, or has signed out.
        public func readBackendURL() -> String? {
            guard let data = readItem(account: backendURLAccount),
                let url = String(data: data, encoding: .utf8), !url.isEmpty
            else { return nil }
            return url
        }

        /// A client for the connection the app signed in with, for code running outside the app's
        /// own connection: the share extension, and the Shortcuts app asking for a list to pick
        /// from. `nil` when signed out. An OIDC sign-in comes back with a client that renews its own
        /// access token, so an extension launched long after the app last ran still gets through.
        public func signedInClient(deviceName: String) -> MVApiClient? {
            guard let url = readBackendURL(), let tokens = read() else { return nil }
            let holder = MVOidcTokenHolder(tokens)
            guard
                let factory = try? MVRequestFactory(
                    baseURL: url, deviceName: deviceName, authProvider: { holder.tokens })
            else { return nil }
            return MVApiClient(requestFactory: factory, credentialRefresher: tokenRefresher(holder: holder))
        }

        /// The one renewer of an OIDC sign-in, for the app and every extension alike: it stores each
        /// new token set here and reads this store before renewing, so the processes sharing the
        /// item spend each refresh token once between them.
        public func tokenRefresher(holder: MVOidcTokenHolder) -> MVTokenRefresher {
            MVTokenRefresher(
                holder: holder,
                // A refresh that finishes after sign-out must not write the session back.
                persist: { tokens in
                    guard read() != nil else { return }
                    _ = write(tokens)
                },
                reload: { read() })
        }

        /// Publishes the backend address for the share extension; `nil` removes it. The app's own
        /// copy stays in `UserDefaults`, so a failed write here costs the extension its address and
        /// nothing else.
        public func writeBackendURL(_ url: String?) {
            guard let url, !url.isEmpty else {
                removeItem(account: backendURLAccount)
                return
            }
            _ = writeItem(Data(url.utf8), account: backendURLAccount)
        }

        private func readItem(account: String) -> Data? {
            var query = baseQuery(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        }

        private func removeItem(account: String) {
            SecItemDelete(baseQuery(account: account) as CFDictionary)
        }

        private func writeItem(_ data: Data, account: String) -> OSStatus {
            removeItem(account: account)
            var query = baseQuery(account: account)
            query[kSecValueData as String] = data
            // Survives a relaunch and works while the phone is locked but has been unlocked once,
            // which is what a background refresh needs. `ThisDeviceOnly` because this is a personal
            // device credential for one self-hosted backend — it has no business migrating through
            // an encrypted backup restore to a different phone, the way the bare `AfterFirstUnlock`
            // form does.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil)
        }
    }
#endif
