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

private actor OutputCollector {
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

        let chunk = String(decoding: data, as: UTF8.self)
        let linesToEmit: [(CommandOutputStream, String)]
        
        switch stream {
        case .stdout:
            stdoutBuffer.append(chunk)
            var lines: [(CommandOutputStream, String)] = []
            while let range = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[..<range.lowerBound]).trimmingCharacters(in: .newlines)
                stdoutBuffer = String(stdoutBuffer[range.upperBound...])
                if !line.isEmpty {
                    stdoutLines.append(line)
                    lines.append((.stdout, line))
                }
            }
            linesToEmit = lines
        case .stderr:
            stderrBuffer.append(chunk)
            var lines: [(CommandOutputStream, String)] = []
            while let range = stderrBuffer.range(of: "\n") {
                let line = String(stderrBuffer[..<range.lowerBound]).trimmingCharacters(in: .newlines)
                stderrBuffer = String(stderrBuffer[range.upperBound...])
                if !line.isEmpty {
                    stderrLines.append(line)
                    lines.append((.stderr, line))
                }
            }
            linesToEmit = lines
        }

        // Emit lines outside of the actor to avoid potential deadlocks
        Task {
            for (stream, line) in linesToEmit {
                onLine?(stream, line)
            }
        }
    }

    func finalize() -> (stdout: [String], stderr: [String]) {
        var linesToEmit: [(CommandOutputStream, String)] = []
        
        let stdoutTail = stdoutBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdoutTail.isEmpty {
            stdoutLines.append(stdoutTail)
            linesToEmit.append((.stdout, stdoutTail))
            stdoutBuffer = ""
        }

        let stderrTail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrTail.isEmpty {
            stderrLines.append(stderrTail)
            linesToEmit.append((.stderr, stderrTail))
            stderrBuffer = ""
        }

        let result = (stdoutLines, stderrLines)

        // Emit lines outside of the actor to avoid potential deadlocks
        Task {
            for (stream, line) in linesToEmit {
                onLine?(stream, line)
            }
        }
        
        return result
    }
}

actor CommandRunner {
    private var activeProcesses: [ObjectIdentifier: Process] = [:]

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

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        
        // Ensure file handles are always closed
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let collector = OutputCollector(onLine: onLine)

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await collector.consume(stream: .stdout, data: data)
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await collector.consume(stream: .stderr, data: data)
            }
        }

        let processID = ObjectIdentifier(process)
        activeProcesses[processID] = process
        defer { activeProcesses[processID] = nil }

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

        // Clear handlers before checking exit code or reading remaining data
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil

        if exitCode == Int32.min {
            throw CommandRunnerError.launchFailed(launchError ?? spec.displayName)
        }

        // Drain any remaining data that arrived after readabilityHandler was cleared
        let remainingStdout = stdoutHandle.readDataToEndOfFile()
        let remainingStderr = stderrHandle.readDataToEndOfFile()
        await collector.consume(stream: .stdout, data: remainingStdout)
        await collector.consume(stream: .stderr, data: remainingStderr)

        let lines = await collector.finalize()
        return CommandResult(exitCode: exitCode, stdoutLines: lines.stdout, stderrLines: lines.stderr)
    }

    func cancelActiveProcess() {
        for process in activeProcesses.values {
            process.terminate()
        }
    }
}
