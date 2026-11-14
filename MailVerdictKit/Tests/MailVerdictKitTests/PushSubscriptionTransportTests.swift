import XCTest

@testable import MailVerdictKit

/// The device list must survive a transport value this build does not know, and read both wire
/// values of a phone.
final class PushSubscriptionTransportTests: XCTestCase {

    private func decode(_ transports: [String]) throws -> [PushSubscriptionResponse] {
        let rows = transports.enumerated().map { index, transport in
            """
            {"id":"00000000-0000-0000-0000-00000000000\(index)","transport":"\(transport)","label":null,
            "alert_folder_ids":null,"reminders_enabled":false,"muted_channels":[],
            "created_at":"2026-01-01T00:00:00Z","last_seen_at":null,"failed_at":null}
            """
        }
        return try JSONDecoder.mvDefault.decode(
            [PushSubscriptionResponse].self, from: Data("[\(rows.joined(separator: ","))]".utf8))
    }

    func testNativeAndTheOlderApnsValueAreBothPhones() throws {
        let devices = try decode(["native", "apns", "webpush"])
        XCTAssertEqual(devices.map(\.transport), [.native, .apns, .webpush])
        XCTAssertEqual(devices.map(\.transport.isPhone), [true, true, false])
    }

    func testAnUnknownTransportDoesNotFailTheList() throws {
        let devices = try decode(["webpush", "carrier-pigeon"])
        XCTAssertEqual(devices.map(\.transport), [.webpush, .unrecognized("carrier-pigeon")])
        XCTAssertFalse(devices[1].transport.isPhone)
    }

    func testAnUnrecognisedDeviceIsSignedOutLikeARevokedOne() {
        let error = MVError.from(statusCode: 401, body: Data(#"{"detail":"device_unrecognised"}"#.utf8))
        XCTAssertTrue(error.isDeviceRevoked)
        XCTAssertTrue(error.endsSession)
        XCTAssertEqual(error.userMessage, "This device was signed out")
    }
}
