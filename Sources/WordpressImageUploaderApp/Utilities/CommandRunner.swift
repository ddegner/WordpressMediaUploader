import Foundation

enum CommandOutputStream {
    case stdout
    case stderr
}

struct CommandSpec {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]?
    var currentDirectoryURL: URL?
    var displayName: String
}

struct CommandResult {
    var exitCode: Int32
    var stdoutLines: [String]
    var stderrLines: [String]
}

enum CommandRunnerError: Error, LocalizedError {
    case launchFailed(String)
    case nonZeroExit(code: Int32, stderrTail: String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return "Failed to launch command: \(message)"
        case let .nonZeroExit(code, stderrTail):
            if stderrTail.isEmpty {
                return "Command failed with exit code \(code)."
            }
            return "Command failed with exit code \(code): \(stderrTail)"
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var stdoutLines: [String] = []
    private var stderrLines: [String] = []

    private let onLine: (@Sendable (CommandOutputStream, String) -> Void)?

    init(onLine: (@Sendable (CommandOutputStream, String) -> Void)?) {
        self.onLine = onLine
    }

    func consume(stream: CommandOutputStream, data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        let chunk = String(decoding: data, as: UTF8.self)
        switch stream {
        case .stdout:
            stdoutBuffer.append(chunk)
            while let range = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[..<range.lowerBound]).trimmingCharacters(in: .newlines)
                stdoutBuffer = String(stdoutBuffer[range.upperBound...])
                emitLocked(stream: .stdout, line: line)
            }
        case .stderr:
            stderrBuffer.append(chunk)
            while let range = stderrBuffer.range(of: "\n") {
                let line = String(stderrBuffer[..<range.lowerBound]).trimmingCharacters(in: .newlines)
                stderrBuffer = String(stderrBuffer[range.upperBound...])
                emitLocked(stream: .stderr, line: line)
            }
        }
        lock.unlock()
    }

    /// Must be called while `lock` is held.
    private func emitLocked(stream: CommandOutputStream, line: String) {
        guard !line.isEmpty else { return }

        switch stream {
        case .stdout:
            stdoutLines.append(line)
        case .stderr:
            stderrLines.append(line)
        }

        onLine?(stream, line)
    }

    func finalize() -> (stdout: [String], stderr: [String]) {
        lock.lock()
        let stdoutTail = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdoutTail.isEmpty {
            emitLocked(stream: .stdout, line: stdoutTail)
            stdoutBuffer = ""
        }

        let stderrTail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrTail.isEmpty {
            emitLocked(stream: .stderr, line: stderrTail)
            stderrBuffer = ""
        }

        let result = (stdoutLines, stderrLines)
        lock.unlock()
        return result
    }
}

actor CommandRunner {
    private var activeProcess: Process?

    func run(
        _ spec: CommandSpec,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments

        if let environment = spec.environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        if let cwd = spec.currentDirectoryURL {
            process.currentDirectoryURL = cwd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector(onLine: onLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.consume(stream: .stdout, data: data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            collector.consume(stream: .stderr, data: data)
        }

        activeProcess = process

        var launchError: String?
        let exitCode = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                launchError = error.localizedDescription
                continuation.resume(returning: Int32.min)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        activeProcess = nil

        if exitCode == Int32.min {
            throw CommandRunnerError.launchFailed(launchError ?? spec.displayName)
        }

        // Drain any remaining data that arrived after readabilityHandler was cleared
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        collector.consume(stream: .stdout, data: remainingStdout)
        collector.consume(stream: .stderr, data: remainingStderr)

        let lines = collector.finalize()
        return CommandResult(exitCode: exitCode, stdoutLines: lines.stdout, stderrLines: lines.stderr)
    }

    func cancelActiveProcess() {
        activeProcess?.terminate()
    }
}
