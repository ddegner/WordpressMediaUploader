import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class ProfileStoreTests: XCTestCase {
    @MainActor
    func testUpsertProfileDoesNotPersistWhenSecretStoreWriteFails() {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-profile-tests-\(UUID().uuidString)", isDirectory: true)
        let profilesFileURL = tempRoot.appendingPathComponent("profiles.json", isDirectory: false)
        let secretStore = MockSecretStore()
        secretStore.setError = MockSecretStoreError.writeFailed

        do {
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create temp directory: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = ProfileStore(secretStore: secretStore, profilesFileURL: profilesFileURL)
        let profile = makePasswordProfile()

        XCTAssertThrowsError(
            try store.upsertProfile(profile, password: "secret", keyPassphrase: "")
        )
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(secretStore.secrets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesFileURL.path))
    }

    @MainActor
    func testUpsertProfileRestoresPreviousSecretWhenPersistenceFails() {
        let secretStore = MockSecretStore()
        let profilesFileURL = URL(fileURLWithPath: "/dev/null")
            .appendingPathComponent("profiles.json", isDirectory: false)
        let store = ProfileStore(secretStore: secretStore, profilesFileURL: profilesFileURL)

        var existing = makePasswordProfile()
        existing.name = "Original"
        existing.passwordKeychainId = "profile-\(existing.id)-password"
        secretStore.secrets[existing.passwordKeychainId ?? ""] = "old-secret"
        store.profiles = [existing]

        var updated = existing
        updated.name = "Updated"

        XCTAssertThrowsError(
            try store.upsertProfile(updated, password: "new-secret", keyPassphrase: "")
        )
        XCTAssertEqual(store.profiles.first?.name, "Original")
        XCTAssertEqual(secretStore.secrets[existing.passwordKeychainId ?? ""], "old-secret")
        XCTAssertTrue(store.lastError?.hasPrefix("Failed to save profiles:") == true)
    }

    private func makePasswordProfile() -> ServerProfile {
        var profile = ServerProfile.default
        profile.id = UUID()
        profile.name = "Production"
        profile.host = "example.com"
        profile.username = "deploy"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/wp-media-import"
        profile.authType = .password
        return profile
    }
}

private enum MockSecretStoreError: Error {
    case writeFailed
}

private final class MockSecretStore: SecretStoring {
    var secrets: [String: String] = [:]
    var setError: MockSecretStoreError?

    func setSecret(_ secret: String, account: String) throws {
        if let setError {
            throw setError
        }
        secrets[account] = secret
    }

    func getSecret(account: String) throws -> String? {
        secrets[account]
    }

    func deleteSecret(account: String) throws {
        secrets[account] = nil
    }
}
