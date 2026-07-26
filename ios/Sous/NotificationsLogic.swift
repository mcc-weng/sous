import Foundation

struct DeviceTokenUpsert: Encodable, Equatable {
    let token: String
    let user_id: UUID
    let platform: String
}

func makeDeviceTokenUpsert(userId: UUID, tokenHex: String) -> DeviceTokenUpsert {
    DeviceTokenUpsert(token: tokenHex, user_id: userId, platform: "ios")
}

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
