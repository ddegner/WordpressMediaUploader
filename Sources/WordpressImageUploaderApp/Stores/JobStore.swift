import Foundation
import Observation

@MainActor
@Observable
final class JobStore {
    private static let maxStoredJobs = 100

    var jobs: [Job] = []

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

    func removeActiveJobs() {
        let before = jobs.count
        let removedLogPaths = jobs
            .filter { JobStep.inFlightSteps.contains($0.step) }
            .map(\.logsPath)
        jobs.removeAll { JobStep.inFlightSteps.contains($0.step) }
        if jobs.count != before {
            if save() {
                cleanupLogFiles(atPaths: removedLogPaths)
            }
        }
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(jobs)
            try data.write(to: AppPaths.jobsFile, options: [.atomic])
            return true
        } catch {
            print("Failed to save jobs: \(error)")
            return false
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: AppPaths.jobsFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([Job].self, from: data)
        } catch {
            jobs = []
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
