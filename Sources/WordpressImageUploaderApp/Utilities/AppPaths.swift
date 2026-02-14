import Foundation

enum AppPaths {
    static let appFolderName = "WordpressMediaUploader"

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(appFolderName, isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    static var profilesFile: URL {
        appSupportDirectory.appendingPathComponent("profiles.json", isDirectory: false)
    }

    static var jobsFile: URL {
        appSupportDirectory.appendingPathComponent("jobs.json", isDirectory: false)
    }

    static var logsDirectory: URL {
        let dir = appSupportDirectory.appendingPathComponent("logs", isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    @discardableResult
    static func ensureDirectory(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}
