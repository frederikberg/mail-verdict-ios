import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif

/// The PKCE (RFC 7636) half of the authorization-code sign-in: a secret the app invents, and the
/// SHA-256 challenge of it that travels in the browser redirect, so an intercepted authorization
/// code is useless to anything that never saw the secret.
public enum MVPkce {

    public struct Pair: Sendable, Equatable {
        public let verifier: String
        public let challenge: String
    }

    /// A fresh verifier (43 characters of 256 random bits) with its `S256` challenge.
    public static func makePair() -> Pair {
        let verifier = randomURLSafeString(byteCount: 32)
        return Pair(verifier: verifier, challenge: challenge(forVerifier: verifier))
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))`, unpadded.
    public static func challenge(forVerifier verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).mvBase64URLEncoded
    }

    /// Unpadded base64url of `byteCount` random bytes — the `state` parameter, and the verifier.
    public static func randomURLSafeString(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).mvBase64URLEncoded
    }
}

extension Data {
    /// RFC 4648 §5 base64url without padding.
    var mvBase64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
