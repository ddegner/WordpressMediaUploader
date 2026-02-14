import XCTest
@testable import WordpressMediaUploaderApp

final class JobRunnerLogicTests: XCTestCase {

    // MARK: - resolvedStagingRoot

    func testResolvedStagingRootTildeOnly() {
        let profile = makeProfile(remoteStagingRoot: "~")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/home/deploy")
    }

    func testResolvedStagingRootTildeSlashPath() {
        let profile = makeProfile(remoteStagingRoot: "~/wp-media-import")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/home/deploy/wp-media-import")
    }

    func testResolvedStagingRootAbsolutePath() {
        let profile = makeProfile(remoteStagingRoot: "/var/staging")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/home/deploy")
        XCTAssertEqual(result, "/var/staging")
    }

    func testResolvedStagingRootTildeSlashNestedPath() {
        let profile = makeProfile(remoteStagingRoot: "~/a/b/c")
        let result = resolvedStagingRoot(profile: profile, homeDirectory: "/root")
        XCTAssertEqual(result, "/root/a/b/c")
    }

    // MARK: - shellSingleQuote edge cases

    func testShellSingleQuoteEmptyString() {
        XCTAssertEqual(shellSingleQuote(""), "''")
    }

    func testShellSingleQuoteWithSingleQuote() {
        XCTAssertEqual(shellSingleQuote("it's"), "'it'\\''s'")
    }

    func testShellSingleQuoteSimple() {
        XCTAssertEqual(shellSingleQuote("hello"), "'hello'")
    }

    // MARK: - prepareFileItems

    @MainActor
    func testPrepareFileItemsEmptyThrows() throws {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        XCTAssertThrowsError(try runner.prepareFileItems(urls: [])) { error in
            XCTAssertTrue(error is JobRunnerError)
        }
    }

    @MainActor
    func testPrepareFileItemsUnsupportedThrows() throws {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        let urls = [URL(fileURLWithPath: "/tmp/test.zip")]
        XCTAssertThrowsError(try runner.prepareFileItems(urls: urls)) { error in
            XCTAssertTrue(error is JobRunnerError)
        }
    }

    @MainActor
    func testPrepareFileItemsAllowsDuplicateBasenamesFromDifferentFolders() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-tests-\(UUID().uuidString)", isDirectory: true)
        let aDir = tempRoot.appendingPathComponent("a", isDirectory: true)
        let bDir = tempRoot.appendingPathComponent("b", isDirectory: true)
        let aFile = aDir.appendingPathComponent("same.jpg", isDirectory: false)
        let bFile = bDir.appendingPathComponent("same.jpg", isDirectory: false)

        try fm.createDirectory(at: aDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: bDir, withIntermediateDirectories: true)
        try Data([0x00, 0x01]).write(to: aFile)
        try Data([0x02, 0x03]).write(to: bFile)

        defer { try? fm.removeItem(at: tempRoot) }

        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        let items = try runner.prepareFileItems(urls: [aFile, bFile])
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - validateProfile

    @MainActor
    func testValidateProfileMissingHostThrows() {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        var profile = ServerProfile.default
        profile.host = ""
        profile.username = "user"
        profile.wpRootPath = "/var/www"
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Host"), "Expected host error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileMissingUsernameThrows() {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = ""
        profile.wpRootPath = "/var/www"
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("Username"), "Expected username error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileMissingWpPathThrows() {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = ""
        profile.remoteStagingRoot = "~/staging"

        XCTAssertThrowsError(try runner.validateProfile(profile)) { error in
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("WordPress"), "Expected WP path error, got: \(desc)")
        }
    }

    @MainActor
    func testValidateProfileValidSSHKeyProfile() {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/staging"
        profile.authType = .sshKey
        profile.keyPath = nil

        XCTAssertNoThrow(try runner.validateProfile(profile))
    }

    @MainActor
    func testValidateProfilePasswordAuthIgnoresMissingSSHKeyPath() {
        let profileStore = ProfileStore()
        let jobStore = JobStore()
        let runner = JobRunner(profileStore: profileStore, jobStore: jobStore)

        var profile = ServerProfile.default
        profile.host = "example.com"
        profile.username = "user"
        profile.wpRootPath = "/var/www/html"
        profile.remoteStagingRoot = "~/staging"
        profile.authType = .password
        profile.keyPath = "/path/that/does/not/exist/id_ed25519"

        XCTAssertNoThrow(try runner.validateProfile(profile, password: "secret"))
    }

    // MARK: - Helpers

    private func makeProfile(remoteStagingRoot: String) -> ServerProfile {
        var profile = ServerProfile.default
        profile.remoteStagingRoot = remoteStagingRoot
        return profile
    }
}
