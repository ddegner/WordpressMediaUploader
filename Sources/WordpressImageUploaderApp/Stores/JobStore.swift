import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.wpmediauploader.app", category: "JobStore")

@MainActor
@Observable
final class JobStore {
    private static let maxStoredJobs = 100

    var jobs: [Job] = []
    var lastError: String?

    init() {
        load()
    }

    func upsert(_ job: Job) {
        var logPathsToDelete: [String] = []

        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            let previousLogPath = jobs[idx].logsPath
            jobs[idx] = job
            if previousLogPath != job.logsPath {
                logPathsToDelete.append(previousLogPath)
            }
        } else {
            jobs.insert(job, at: 0)
        }

        jobs.sort { $0.createdAt > $1.createdAt }
        if jobs.count > Self.maxStoredJobs {
            let removed = jobs[Self.maxStoredJobs...]
            logPathsToDelete.append(contentsOf: removed.map(\.logsPath))
            jobs = Array(jobs.prefix(Self.maxStoredJobs))
        }

        if save() {
            cleanupLogFiles(atPaths: logPathsToDelete)
        }
    }

    func clear() {
        let logPaths = jobs.map(\.logsPath)
        jobs.removeAll()
        if save() {
            cleanupLogFiles(atPaths: logPaths)
        }
    }

    func job(id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(jobs)
            try data.write(to: AppPaths.jobsFile, options: [.atomic])
            lastError = nil
            return true
        } catch {
            lastError = "Failed to save job history: \(error.localizedDescription)"
            logger.error("Failed to save jobs: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func load() {
        let fileURL = AppPaths.jobsFile
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            jobs = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([Job].self, from: data)
        } catch {
            jobs = []
            lastError = "Job history could not be read and was reset. (\(error.localizedDescription))"
            logger.error("Failed to load jobs: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cleanupLogFiles(atPaths paths: [String]) {
        guard !paths.isEmpty else { return }

        let fileManager = FileManager.default
        let uniquePaths = Set(paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })

        for path in uniquePaths where !path.isEmpty {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }
}
