import XCTest

@testable import MailVerdictKit

final class FolderPipelineSwitchTests: XCTestCase {
    private let ids = (
        folder: "7c1f4f0e-5a52-4d4e-9b0b-6f3b3f3a1a01",
        account: "7c1f4f0e-5a52-4d4e-9b0b-6f3b3f3a1a02"
    )

    func testFolderResponseReadsTheSwitchAndDefaultsToOn() throws {
        let off = """
            {"id":"\(ids.folder)","account_id":"\(ids.account)","imap_name":"Label","pipeline_enabled":false}
            """
        let absent = """
            {"id":"\(ids.folder)","account_id":"\(ids.account)","imap_name":"INBOX"}
            """
        let decoder = JSONDecoder.mvDefault
        XCTAssertFalse(try decoder.decode(FolderResponse.self, from: Data(off.utf8)).pipelineEnabled)
        XCTAssertTrue(try decoder.decode(FolderResponse.self, from: Data(absent.utf8)).pipelineEnabled)
    }

    func testFolderOrderItemReadsTheSwitchAndDefaultsToOn() throws {
        let off = """
            {"folder_id":"\(ids.folder)","imap_name":"Label","pipeline_enabled":false}
            """
        let absent = """
            {"folder_id":"\(ids.folder)","imap_name":"INBOX"}
            """
        let decoder = JSONDecoder.mvDefault
        XCTAssertFalse(try decoder.decode(FolderOrderItem.self, from: Data(off.utf8)).pipelineEnabled)
        XCTAssertTrue(try decoder.decode(FolderOrderItem.self, from: Data(absent.utf8)).pipelineEnabled)
    }

    func testPrefsUpdateSendsTheSwitchOnlyWhenSet() throws {
        let encoder = JSONEncoder.mvDefault
        let set = try encoder.encode(FolderPrefsUpdate(pipelineEnabled: false))
        let unset = try encoder.encode(FolderPrefsUpdate(isVisible: true))
        let setObject = try XCTUnwrap(JSONSerialization.jsonObject(with: set) as? [String: Any])
        let unsetObject = try XCTUnwrap(JSONSerialization.jsonObject(with: unset) as? [String: Any])
        XCTAssertEqual(setObject["pipeline_enabled"] as? Bool, false)
        XCTAssertNil(unsetObject["pipeline_enabled"])
    }
}
