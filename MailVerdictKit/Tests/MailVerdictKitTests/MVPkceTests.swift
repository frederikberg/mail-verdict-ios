import XCTest

@testable import MailVerdictKit

final class MVPkceTests: XCTestCase {

    /// RFC 7636 appendix B's own vector, so the challenge is not checked against the SHA-256 call
    /// the implementation makes.
    func testChallengeMatchesTheRfcVector() {
        XCTAssertEqual(
            MVPkce.challenge(forVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierIsWithinTheAllowedLengthAndAlphabet() {
        let pair = MVPkce.makePair()
        XCTAssertTrue((43...128).contains(pair.verifier.count))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(pair.verifier.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(pair.challenge, MVPkce.challenge(forVerifier: pair.verifier))
    }

    func testEveryPairAndStateIsDifferent() {
        XCTAssertNotEqual(MVPkce.makePair().verifier, MVPkce.makePair().verifier)
        XCTAssertNotEqual(MVPkce.randomURLSafeString(), MVPkce.randomURLSafeString())
    }
}
