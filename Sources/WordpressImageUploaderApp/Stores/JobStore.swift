import Foundation
import Observation

@MainActor
@Observable
final class JobStore {
    var jobs: [Job] = []

    init() {
        load()
    }

    func upsert(_ job: Job) {
        if let idx = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[idx] = job
        } else {
            jobs.insert(job, at: 0)
        }

        jobs.sort { $0.createdAt > $1.createdAt }
        if jobs.count > 100 {
            jobs = Array(jobs.prefix(100))
        }

        save()
    }

    func clear() {
        jobs.removeAll()
        save()
    }

    func job(id: UUID) -> Job? {
        jobs.first { $0.id == id }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(jobs)
            try data.write(to: AppPaths.jobsFile, options: [.atomic])
        } catch {
            print("Failed to save jobs: \(error)")
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
}
