import XCTest
@testable import WordpressMediaUploaderApp

final class ServerProfileCodingTests: XCTestCase {
    func testDecodingLegacyProfileWithoutSoundSettingDefaultsToFalse() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "Production",
          "host": "example.com",
          "port": 22,
          "username": "deploy",
          "authType": "password",
          "wpRootPath": "/var/www/html",
          "remoteStagingRoot": "~/wp-media-import",
          "keepRemoteFiles": false
        }
        """

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.playCompletionSoundOnCompletion)
    }

    func testEncodeDecodeRoundTripPreservesSoundSetting() throws {
        var profile = ServerProfile.default
        profile.name = "With sound"
        profile.playCompletionSoundOnCompletion = true

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertTrue(decoded.playCompletionSoundOnCompletion)
    }
}
