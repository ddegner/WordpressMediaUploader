import Foundation
import XCTest
@testable import WordpressMediaUploaderApp

final class LogWriterTests: XCTestCase {
    func testDeinitFlushesQueuedLogLines() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wp-uploader-log-tests-\(UUID().uuidString)", isDirectory: true)
        let logURL = tempRoot.appendingPathComponent("job.log", isDirectory: false)

        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let expectedLineCount = 500

        weak var weakWriter: LogWriter?
        do {
            let writer = LogWriter(fileURL: logURL)
            weakWriter = writer
            for index in 0..<expectedLineCount {
                writer.append("line \(index)")
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while weakWriter != nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertNil(weakWriter)
        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(
            contents.split(separator: "\n", omittingEmptySubsequences: true).count,
            expectedLineCount
        )
    }
}
