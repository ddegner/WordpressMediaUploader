import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class FileDropHelperTests: XCTestCase {
    func testResolveImageFileURLsFiltersUnsupportedFiles() throws {
        let fm = FileManager.default
        let root = temporaryRoot()
        let image = root.appendingPathComponent("photo.jpg")
        let text = root.appendingPathComponent("notes.txt")

        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x00]).write(to: image)
        try Data([0x01]).write(to: text)
        defer { try? fm.removeItem(at: root) }

        let resolved = resolveImageFileURLs(from: [image, text])
        XCTAssertEqual(resolved.map(\.lastPathComponent), ["photo.jpg"])
    }

    func testResolveImageFileURLsRecursesDirectories() throws {
        let fm = FileManager.default
        let root = temporaryRoot()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let jpg = root.appendingPathComponent("a.jpg")
        let png = nested.appendingPathComponent("b.png")
        let pdf = nested.appendingPathComponent("c.pdf")

        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x00]).write(to: jpg)
        try Data([0x01]).write(to: png)
        try Data([0x02]).write(to: pdf)
        defer { try? fm.removeItem(at: root) }

        let resolved = resolveImageFileURLs(from: [root])
        let names = Set(resolved.map(\.lastPathComponent))
        XCTAssertEqual(names, Set(["a.jpg", "b.png"]))
    }

    func testResolveImageFileURLsDeduplicatesByPath() throws {
        let fm = FileManager.default
        let root = temporaryRoot()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let image = nested.appendingPathComponent("dup.webp")

        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x00]).write(to: image)
        defer { try? fm.removeItem(at: root) }

        let resolved = resolveImageFileURLs(from: [root, image])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.lastPathComponent, "dup.webp")
    }

    private func temporaryRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-drop-tests-\(UUID().uuidString)", isDirectory: true)
    }
}
