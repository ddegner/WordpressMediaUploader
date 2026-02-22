import XCTest
@testable import WordpressMediaUploaderApp

final class FileRowStatusTests: XCTestCase {
    func testResolveShowsPreflightForCurrentJobQueuedItemDuringPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: false,
            isActiveFile: false,
            currentStep: .preflight
        )

        XCTAssertEqual(status, .preflight)
        XCTAssertEqual(status.label, "preflight")
    }

    func testResolveKeepsQueuedForQueuedSourceDuringPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let status = FileRowStatus.resolve(
            item: item,
            isQueuedSource: true,
            isActiveFile: false,
            currentStep: .preflight
        )

        XCTAssertEqual(status, .queued)
    }

    func testHelpTextUsesPreflightMessageWhenRowStatusIsPreflight() {
        let item = FileItem(
            localURL: URL(fileURLWithPath: "/tmp/a.jpg"),
            filename: "a.jpg",
            sizeBytes: 1
        )

        let text = FileRowPresentation.helpText(
            for: item,
            rowStatus: .preflight,
            isQueuedSource: false
        )

        XCTAssertEqual(text, "Running preflight checks and preparing staging.")
    }
}
