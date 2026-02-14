import XCTest
@testable import WordpressMediaUploaderApp

final class ShellHelpersTests: XCTestCase {
    func testParseRsyncProgressParsesPercent() {
        let line = "      52,428,800  63%   19.17MB/s    0:00:01"
        let parsed = parseRsyncProgress(line)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!, 0.63, accuracy: 0.0001)
    }

    func testParseRsyncProgressReturnsNilWhenMissing() {
        XCTAssertNil(parseRsyncProgress("sending incremental file list"))
    }

    func testEnsureNoTrailingSlash() {
        XCTAssertEqual(ensureNoTrailingSlash("/var/www/site/"), "/var/www/site")
        XCTAssertEqual(ensureNoTrailingSlash("/"), "/")
    }

    func testIsSupportedImageExtension() {
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.JPG")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.avif")))
        XCTAssertFalse(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/archive.zip")))
    }
}
