import XCTest
@testable import WordpressMediaUploaderApp

final class ServerProfileCodingTests: XCTestCase {
    func testDecodingLegacyProfileWithoutDeprecatedSoundSettingStillSucceeds() throws {
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
        XCTAssertEqual(decoded.id, id)
        XCTAssertFalse(decoded.keepRemoteFiles)
    }

    func testDecodingLegacyProfileWithDeprecatedSoundSettingIgnoresField() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "name": "With sound",
          "host": "example.com",
          "port": 22,
          "username": "deploy",
          "authType": "password",
          "wpRootPath": "/var/www/html",
          "remoteStagingRoot": "~/wp-media-import",
          "keepRemoteFiles": false,
          "playCompletionSoundOnCompletion": true
        }
        """

        let decoded = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let encodedString = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(decoded.name, "With sound")
        XCTAssertFalse(encodedString.contains("playCompletionSoundOnCompletion"))
    }
}
