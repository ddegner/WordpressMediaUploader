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
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.jpe")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.gif")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.bmp")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.ico")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.heic")))
        XCTAssertTrue(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/doc.pdf")))
        XCTAssertFalse(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/photo.tiff")))
        XCTAssertFalse(isSupportedImageExtension(URL(fileURLWithPath: "/tmp/archive.zip")))
    }
}
