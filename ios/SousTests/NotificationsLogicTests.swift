import XCTest
@testable import Sous

final class NotificationsLogicTests: XCTestCase {
    func testMakeDeviceTokenUpsertShapesPayload() {
        let userId = UUID()
        let upsert = makeDeviceTokenUpsert(userId: userId, tokenHex: "abcd1234")
        XCTAssertEqual(upsert, DeviceTokenUpsert(
            token: "abcd1234", user_id: userId, platform: "ios"
        ))
    }

    func testDeviceTokenHexEncodingMatchesAPNsFormat() {
        // APNs device tokens are lowercase hex with no separators — the bytes handed
        // back by didRegisterForRemoteNotificationsWithDeviceToken must be encoded this
        // way, not left as Data's default description (which includes spaces/angle
        // brackets and would silently fail to match on APNs's side).
        let bytes = Data([0x0A, 0xFF, 0x00, 0x1B])
        XCTAssertEqual(hexString(bytes), "0aff001b")
    }
}
