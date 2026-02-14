import XCTest
@testable import WordpressMediaUploaderApp

final class ReportBuilderTests: XCTestCase {
    func testCSVReportEscapesCommasAndQuotes() {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/img,\"quote\".jpg"), filename: "img,\"quote\".jpg", sizeBytes: 1234)
        file.status = .failed
        file.errorMessage = "Bad, \"error\""

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/remote-job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .failed

        let csv = ReportBuilder.csvReport(for: job)
        XCTAssertTrue(csv.contains("\"img,\"\"quote\"\".jpg\""))
        XCTAssertTrue(csv.contains("\"Bad, \"\"error\"\"\""))
    }

    func testJSONReportContainsExpectedCoreFields() throws {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .regenerated
        file.importAttachmentId = 42

        var job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )
        job.step = .finished
        job.importedIds = [42]

        let json = try ReportBuilder.jsonReport(for: job)
        XCTAssertTrue(json.contains("\"status\" : \"finished\""))
        XCTAssertTrue(json.contains("\"importedIds\""))
        XCTAssertTrue(json.contains("\"attachmentId\" : 42"))
    }

    func testTextReportContainsFileStatus() {
        var file = FileItem(localURL: URL(fileURLWithPath: "/tmp/a.jpg"), filename: "a.jpg", sizeBytes: 10)
        file.status = .imported

        let job = Job(
            profileId: UUID(),
            remoteJobDir: "/tmp/job",
            files: [file],
            logsPath: "/tmp/log.txt"
        )

        let text = ReportBuilder.textReport(for: job)
        XCTAssertTrue(text.contains("a.jpg: imported"))
    }
}
