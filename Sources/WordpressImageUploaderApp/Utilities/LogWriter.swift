import Foundation

final class LogWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "WordpressMediaUploader.LogWriter")
    private let dateFormatter = ISO8601DateFormatter()
    private var handle: FileHandle?

    init(fileURL: URL) {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        self.handle = try? FileHandle(forWritingTo: fileURL)
        if let handle = self.handle {
            do {
                _ = try handle.seekToEnd()
            } catch {
                print("Failed to seek log file: \(error)")
            }
        }
    }

    deinit {
        if let handle {
            do {
                try handle.close()
            } catch {
                // Best-effort close; nothing to do on failure.
            }
        }
    }

    func append(_ line: String) {
        let timestamp = dateFormatter.string(from: Date())
        let payload = "[\(timestamp)] \(line)\n"
        guard let data = payload.data(using: .utf8) else { return }

        queue.async { [weak self] in
            guard let handle = self?.handle else { return }
            do {
                try handle.write(contentsOf: data)
            } catch {
                print("Failed to write log: \(error)")
            }
        }
    }
}
