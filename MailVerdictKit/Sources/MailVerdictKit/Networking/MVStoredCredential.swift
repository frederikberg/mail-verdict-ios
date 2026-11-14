import Foundation

/// Reads what the Keychain item holds, across the shapes earlier versions wrote. Pure, so the
/// rules run on every platform; `MVKeychainCredentialStore` does the storing.
public enum MVStoredCredential: Equatable {
    /// The sign-in's token set, in the shape written today.
    case current(MVOidcTokens)
    /// An OIDC sign-in written by an earlier version, still good: the caller rewrites it in the
    /// current shape.
    case migrated(MVOidcTokens)
    /// Nothing usable: unreadable, empty, or a pasted key, basic-auth pair or "no credential"
    /// from an earlier version. The caller removes the item.
    case unusable

    public static func decode(_ data: Data) -> MVStoredCredential {
        let decoder = JSONDecoder()
        if let tokens = try? decoder.decode(MVOidcTokens.self, from: data) {
            return tokens.isUsable ? .current(tokens) : .unusable
        }
        if let legacy = try? decoder.decode(LegacyCredential.self, from: data), let tokens = legacy.oidc?._0,
            tokens.isUsable
        {
            return .migrated(tokens)
        }
        return .unusable
    }

    /// The enum of credential modes earlier versions encoded, as Swift's synthesized `Codable`
    /// wrote it (`{"oidc":{"_0":{…}}}`). Its other cases — `none`, `bearer`, `basic` — have no
    /// counterpart: nothing reads them.
    private struct LegacyCredential: Decodable {
        struct OidcCase: Decodable { let _0: MVOidcTokens }
        let oidc: OidcCase?
    }
}

extension MVOidcTokens {
    /// A token set with neither token is unusable; one with only a refresh token is not, since
    /// the first request refreshes it.
    var isUsable: Bool { !(accessToken.isEmpty && refreshToken == nil) }
}
