import Foundation
import Observation

enum JobRunnerError: LocalizedError {
    case missingFiles
    case unsupportedImages
    case profileIncomplete(String)
    case authSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingFiles:
            return "No files selected."
        case .unsupportedImages:
            return "No supported image files were selected."
        case let .profileIncomplete(detail):
            return "Profile is incomplete: \(detail)"
        case let .authSetupFailed(detail):
            return "Failed to configure SSH authentication: \(detail)"
        }
    }
}

@MainActor
@Observable
final class JobRunner {
    var currentJob: Job?
    var logLines: [String] = []
    var isRunning = false
    var errorBanner: String?

    private let profileStore: ProfileStore
    private let jobStore: JobStore
    private let transport: SSHTransport

    private var activeTask: Task<Void, Never>?
    private var activeRunJobID: UUID?
    private var isCancelling = false

    init(profileStore: ProfileStore, jobStore: JobStore) {
        self.profileStore = profileStore
        self.jobStore = jobStore
        self.transport = SSHTransport(profileStore: profileStore)
        recoverInterruptedJobs()
        self.currentJob = jobStore.jobs.first
        if let job = jobStore.jobs.first {
            self.logLines = readLogLines(atPath: job.logsPath)
        }
    }

    var canRetryFailed: Bool {
        guard !isRunning, let job = currentJob else { return false }
        return job.localFiles.contains { $0.status == .failed }
    }

    func start(profile: ServerProfile, fileURLs: [URL]) {
        guard !isRunning else { return }

        do {
            let fileItems = try prepareFileItems(urls: fileURLs)
            let jobId = UUID()
            let remoteJobDir = "\(ensureNoTrailingSlash(profile.remoteStagingRoot))/\(jobId.uuidString)"
            let logsPath = AppPaths.logsDirectory
                .appendingPathComponent("\(jobId.uuidString).log", isDirectory: false)
                .path

            var job = Job(profileId: profile.id, remoteJobDir: remoteJobDir, files: fileItems, logsPath: logsPath)
            job.id = jobId

            currentJob = job
            logLines = []
            errorBanner = nil
            jobStore.upsert(job)

            runPipeline(profile: profile, jobID: job.id)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func retryFailed(profile: ServerProfile) {
        guard !isRunning else { return }
        guard let selectedJob = currentJob else { return }

        guard selectedJob.profileId == profile.id else {
            errorBanner = "The selected profile does not match the job's original profile."
            return
        }

        mutateJob(id: selectedJob.id) { job in
            for idx in job.localFiles.indices {
                guard job.localFiles[idx].status == .failed else { continue }

                if job.localFiles[idx].importAttachmentId != nil {
                    job.localFiles[idx].status = .imported
                } else {
                    job.localFiles[idx].status = .queued
                    job.localFiles[idx].remotePath = nil
                }
                job.localFiles[idx].errorMessage = nil
            }

            job.step = .preflight
            job.errorMessage = nil
            job.uploadProgress = 0
            job.importProgress = 0
            job.activeFileId = nil
        }

        runPipeline(profile: profile, jobID: selectedJob.id)
    }

    func cancel() {
        guard isRunning else { return }

        isCancelling = true
        if let activeRunJobID {
            mutateJob(id: activeRunJobID) { job in
                job.step = .cancelled
                job.errorMessage = "Cancellation requested"
                job.activeFileId = nil
            }
        }

        appendLog("Cancellation requested by user.", writer: nil)

        activeTask?.cancel()
        Task {
            await transport.cancelActiveProcess()
        }
    }

    func reportText() -> String {
        guard let job = currentJob else {
            return "No job has run yet."
        }

        return ReportBuilder.textReport(for: job)
    }

    func reportPayload(format: ReportExportFormat) -> String? {
        guard let job = currentJob else { return nil }

        switch format {
        case .text:
            return ReportBuilder.textReport(for: job)
        case .json:
            return try? ReportBuilder.jsonReport(for: job)
        case .csv:
            return ReportBuilder.csvReport(for: job)
        }
    }

    func suggestedReportFileName(format: ReportExportFormat) -> String {
        guard let job = currentJob else {
            return "wp-media-job-report.\(format.fileExtension)"
        }
        return "wp-media-job-\(job.id.uuidString).\(format.fileExtension)"
    }

    func loadJob(_ job: Job) {
        if isRunning {
            errorBanner = "Cannot switch jobs while a run is active."
            return
        }

        currentJob = job
        errorBanner = nil
        logLines = readLogLines(atPath: job.logsPath)
    }

    func clearJobHistory() {
        guard !isRunning else { return }
        jobStore.clear()
        currentJob = nil
        logLines = []
        errorBanner = nil
    }

    func testConnection(profile: ServerProfile, password: String?, keyPassphrase: String?) async -> ProfileTestResult {
        var checks: [String] = []
        var authContext: SSHAuthContext?
        defer {
            authContext?.cleanup()
        }

        do {
            try validateProfile(profile, password: password)
            let auth = try transport.makeAuthContext(for: profile, password: password, keyPassphrase: keyPassphrase)
            authContext = auth

            let home = try await transport.fetchRemoteHomeDirectory(profile: profile, auth: auth, writer: nil)

            _ = try await transport.runSSH(profile: profile, auth: auth, remoteCommand: "uname -a", writer: nil)
            checks.append("SSH OK")

            try await transport.runPreflightChecks(profile: profile, auth: auth, writer: nil)
            checks.append("WP-CLI OK")
            checks.append("WP detected")

            let stagingRoot = resolvedStagingRoot(profile: profile, homeDirectory: home)
            let writableCmd = "mkdir -p \(shellSingleQuote(stagingRoot)) && test -w \(shellSingleQuote(stagingRoot))"
            _ = try await transport.runSSH(profile: profile, auth: auth, remoteCommand: writableCmd, writer: nil)
            checks.append("Writable staging OK")

            return ProfileTestResult(checks: checks, success: true)
        } catch {
            checks.append(error.localizedDescription)
            return ProfileTestResult(checks: checks, success: false)
        }
    }

    // MARK: - Pipeline

    private func runPipeline(profile: ServerProfile, jobID: UUID) {
        activeRunJobID = jobID
        isRunning = true
        isCancelling = false
        errorBanner = nil

        activeTask = Task { [weak self] in
            guard let self else { return }

            defer {
                self.isRunning = false
                self.isCancelling = false
                self.activeTask = nil
                self.activeRunJobID = nil
            }

            guard let job = self.jobSnapshot(id: jobID) else {
                self.errorBanner = "The selected job no longer exists."
                return
            }

            let logURL = URL(fileURLWithPath: job.logsPath)
            let writer = LogWriter(fileURL: logURL)
            self.appendLog("Job started: \(job.id.uuidString)", writer: writer)

            let logger = self.lineLogger(writer: writer)
            var authContext: SSHAuthContext?
            defer {
                authContext?.cleanup()
            }

            do {
                try self.validateProfile(profile)
                let auth = try self.transport.makeAuthContext(for: profile)
                authContext = auth

                try Task.checkCancellation()
                let home = try await self.transport.fetchRemoteHomeDirectory(
                    profile: profile,
                    auth: auth,
                    writer: writer,
                    onLine: logger
                )

                let resolvedRoot = resolvedStagingRoot(profile: profile, homeDirectory: home)
                self.mutateJob(id: jobID) { mutable in
                    mutable.remoteJobDir = "\(ensureNoTrailingSlash(resolvedRoot))/\(mutable.id.uuidString)"
                }

                try Task.checkCancellation()
                try await self.preflight(profile: profile, auth: auth, writer: writer, jobID: jobID)

                try Task.checkCancellation()
                try await self.ensureRemoteJobDirectories(profile: profile, auth: auth, writer: writer, jobID: jobID)

                try Task.checkCancellation()
                await self.uploadAndVerify(profile: profile, auth: auth, writer: writer, jobID: jobID)

                try Task.checkCancellation()
                await self.importVerifiedFiles(profile: profile, auth: auth, writer: writer, jobID: jobID)

                try Task.checkCancellation()
                await self.regenerateImported(profile: profile, auth: auth, writer: writer, jobID: jobID)

                try Task.checkCancellation()
                if !profile.keepRemoteFiles {
                    await self.cleanupRemoteFiles(profile: profile, auth: auth, writer: writer, jobID: jobID)
                }

                self.finishJob(jobID: jobID)
            } catch is CancellationError {
                self.markJobCancelled(jobID: jobID, writer: writer)
            } catch {
                if self.isCancelling {
                    self.markJobCancelled(jobID: jobID, writer: writer)
                } else {
                    self.appendLog("Job failed: \(error.localizedDescription)", writer: writer)
                    self.mutateJob(id: jobID) { mutable in
                        mutable.step = .failed
                        mutable.errorMessage = error.localizedDescription
                        mutable.activeFileId = nil
                    }
                    self.errorBanner = error.localizedDescription
                }
            }
        }
    }

    private func finishJob(jobID: UUID) {
        guard let job = jobSnapshot(id: jobID) else { return }

        if job.localFiles.contains(where: { $0.status == .failed }) {
            mutateJob(id: jobID) { mutable in
                mutable.step = .failed
                mutable.errorMessage =
                    "\(mutable.failedCount) file(s) failed. Use Retry Failed to rerun only failed steps."
                mutable.activeFileId = nil
            }
            errorBanner = jobSnapshot(id: jobID)?.errorMessage
        } else {
            mutateJob(id: jobID) { mutable in
                mutable.step = .finished
                mutable.errorMessage = nil
                mutable.uploadProgress = 1
                mutable.importProgress = 1
                mutable.activeFileId = nil
            }
        }
    }

    private func markJobCancelled(jobID: UUID, writer: LogWriter) {
        appendLog("Job cancelled.", writer: writer)
        mutateJob(id: jobID) { mutable in
            mutable.step = .cancelled
            mutable.errorMessage = "Cancelled by user"
            mutable.activeFileId = nil
        }
        errorBanner = "Job cancelled."
    }

    // MARK: - Pipeline steps

    private func preflight(profile: ServerProfile, auth: SSHAuthContext, writer: LogWriter, jobID: UUID) async throws {
        mutateJob(id: jobID) {
            $0.step = .preflight
            $0.activeFileId = nil
        }

        let logger = lineLogger(writer: writer)

        try await transport.runPreflightChecks(
            profile: profile,
            auth: auth,
            writer: writer,
            onLine: logger
        )

        _ = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "wp --path=\(shellSingleQuote(profile.wpRootPath)) core version",
            writer: writer,
            onLine: logger
        )
    }

    private func ensureRemoteJobDirectories(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async throws {
        guard let job = jobSnapshot(id: jobID) else { return }

        let incoming = incomingDirectory(for: job)
        let command = "mkdir -p \(shellSingleQuote(incoming))"
        _ = try await transport.runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: lineLogger(writer: writer)
        )
    }

    private func uploadAndVerify(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async {
        guard let job = jobSnapshot(id: jobID) else { return }

        mutateJob(id: jobID) {
            $0.step = .uploading
            $0.uploadProgress = 0
            $0.activeFileId = nil
        }

        let candidates = job.localFiles.filter { $0.status == .queued }
        if candidates.isEmpty {
            mutateJob(id: jobID) {
                $0.uploadProgress = 1
            }
        } else {
            let incomingDir = incomingDirectory(for: job)
            let logger = lineLogger(writer: writer)

            do {
                let remoteDirs = candidates.map { shellSingleQuote("\(incomingDir)/\($0.id.uuidString)") }
                let mkdirCmd = "mkdir -p \(remoteDirs.joined(separator: " "))"
                _ = try await transport.runSSH(
                    profile: profile,
                    auth: auth,
                    remoteCommand: mkdirCmd,
                    writer: writer,
                    onLine: logger
                )

                for (index, file) in candidates.enumerated() {
                    mutateJob(id: jobID) { mutable in
                        mutable.activeFileId = file.id
                    }
                    do {
                        let remotePath = remoteUploadPath(incomingDir: incomingDir, file: file)

                        try await transport.runRsyncFile(
                            profile: profile,
                            auth: auth,
                            localFileURL: file.localURL,
                            remoteTargetPath: remoteUploadDirectory(incomingDir: incomingDir, file: file) + "/",
                            writer: writer
                        ) { [weak self] stream, line in
                            Task { @MainActor in
                                guard let self else { return }
                                self.appendLog("[\(stream == .stdout ? "out" : "err")] \(line)", writer: writer)
                                if stream == .stdout, let fileProgress = parseRsyncProgress(line) {
                                    let total = Double(candidates.count)
                                    let combined = (Double(index) + fileProgress) / total
                                    self.mutateJob(id: jobID) { mutable in
                                        mutable.uploadProgress = combined
                                    }
                                }
                            }
                        }

                        mutateJob(id: jobID) { mutable in
                            if let idx = mutable.localFiles.firstIndex(where: { $0.id == file.id }) {
                                mutable.localFiles[idx].remotePath = remotePath
                                mutable.localFiles[idx].status = .uploaded
                                mutable.localFiles[idx].errorMessage = nil
                            }
                            mutable.uploadProgress = Double(index + 1) / Double(candidates.count)
                        }
                    } catch {
                        mutateJob(id: jobID) { mutable in
                            if let idx = mutable.localFiles.firstIndex(where: { $0.id == file.id }) {
                                mutable.localFiles[idx].status = .failed
                                mutable.localFiles[idx].errorMessage = error.localizedDescription
                                mutable.localFiles[idx].remotePath = nil
                            }
                            mutable.uploadProgress = Double(index + 1) / Double(candidates.count)
                        }
                    }
                }
            } catch {
                appendLog("Upload setup failed: \(error.localizedDescription)", writer: writer)
                mutateJob(id: jobID) { mutable in
                    for idx in mutable.localFiles.indices {
                        guard candidates.contains(where: { $0.id == mutable.localFiles[idx].id }) else { continue }
                        mutable.localFiles[idx].status = .failed
                        mutable.localFiles[idx].errorMessage = error.localizedDescription
                        mutable.localFiles[idx].remotePath = nil
                    }
                }
            }
        }

        mutateJob(id: jobID) {
            $0.step = .verifying
            $0.activeFileId = nil
        }

        await verifyUploadedFiles(profile: profile, auth: auth, writer: writer, jobID: jobID)
    }

    private func verifyUploadedFiles(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async {
        guard let job = jobSnapshot(id: jobID) else { return }

        let verifyTargets = job.localFiles.filter { $0.status == .uploaded }
        if verifyTargets.isEmpty {
            return
        }

        for file in verifyTargets {
            mutateJob(id: jobID) { mutable in
                mutable.activeFileId = file.id
            }
            do {
                guard let remotePath = file.remotePath else {
                    throw JobRunnerError.profileIncomplete("Missing remote path for \(file.filename)")
                }

                let remoteSize = try await transport.fetchRemoteFileSize(
                    profile: profile,
                    auth: auth,
                    remotePath: remotePath,
                    writer: writer,
                    onLine: lineLogger(writer: writer)
                )

                if remoteSize == file.sizeBytes {
                    updateFile(jobID: jobID, id: file.id) {
                        $0.status = .verified
                        $0.errorMessage = nil
                    }
                } else {
                    updateFile(jobID: jobID, id: file.id) {
                        $0.status = .failed
                        $0.errorMessage = "Size mismatch (local \(file.sizeBytes) bytes, remote \(remoteSize) bytes)"
                    }
                }
            } catch {
                updateFile(jobID: jobID, id: file.id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }

        mutateJob(id: jobID) { mutable in
            mutable.activeFileId = nil
        }
    }

    private func importVerifiedFiles(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async {
        guard let job = jobSnapshot(id: jobID) else { return }

        mutateJob(id: jobID) {
            $0.step = .importing
            $0.importProgress = 0
            $0.activeFileId = nil
        }

        let importTargets = job.localFiles.filter { $0.status == .verified }
        if importTargets.isEmpty {
            mutateJob(id: jobID) {
                $0.importProgress = 1
            }
            return
        }

        for (index, file) in importTargets.enumerated() {
            mutateJob(id: jobID) { mutable in
                mutable.activeFileId = file.id
            }
            do {
                guard let remotePath = file.remotePath else {
                    throw JobRunnerError.profileIncomplete("Missing remote path for \(file.filename)")
                }

                appendLog("Importing file \(index + 1)/\(importTargets.count): \(file.filename)", writer: writer)

                let wpPath = shellSingleQuote(profile.wpRootPath)
                let remoteSQ = shellSingleQuote(remotePath)
                let baseCommand = "wp --path=\(wpPath) media import \(remoteSQ) --porcelain"
                let command = wrapWithOptionalTimeout(command: baseCommand, seconds: 600)
                let result = try await transport.runSSH(
                    profile: profile,
                    auth: auth,
                    remoteCommand: command,
                    writer: writer,
                    onLine: lineLogger(writer: writer)
                )

                let idLine = result.stdoutLines
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { Int($0) != nil }

                guard let idLine, let attachmentId = Int(idLine) else {
                    throw JobRunnerError.profileIncomplete("Import did not return attachment ID for \(file.filename)")
                }

                appendLog("Imported \(file.filename) as attachment ID \(attachmentId).", writer: writer)
                mutateJob(id: jobID) { mutable in
                    if let idx = mutable.localFiles.firstIndex(where: { $0.id == file.id }) {
                        mutable.localFiles[idx].status = .imported
                        mutable.localFiles[idx].importAttachmentId = attachmentId
                        mutable.localFiles[idx].errorMessage = nil
                    }

                    if !mutable.importedIds.contains(attachmentId) {
                        mutable.importedIds.append(attachmentId)
                    }

                    mutable.importProgress = Double(index + 1) / Double(importTargets.count)
                }
            } catch {
                let message = timeoutAwareMessage(
                    for: error,
                    fallback: "Import failed for \(file.filename): \(error.localizedDescription)"
                )
                appendLog(message, writer: writer)
                mutateJob(id: jobID) { mutable in
                    if let idx = mutable.localFiles.firstIndex(where: { $0.id == file.id }) {
                        mutable.localFiles[idx].status = .failed
                        mutable.localFiles[idx].errorMessage = message
                    }
                    mutable.importProgress = Double(index + 1) / Double(importTargets.count)
                }
            }
        }

        mutateJob(id: jobID) { mutable in
            mutable.activeFileId = nil
        }
    }

    private func regenerateImported(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async {
        guard let job = jobSnapshot(id: jobID) else { return }

        mutateJob(id: jobID) {
            $0.step = .regenerating
            $0.activeFileId = nil
        }

        let targets = job.localFiles.filter {
            $0.importAttachmentId != nil && $0.status != .regenerated
        }

        if targets.isEmpty {
            return
        }

        for file in targets {
            mutateJob(id: jobID) { mutable in
                mutable.activeFileId = file.id
            }
            do {
                guard let attachmentId = file.importAttachmentId else { continue }
                let wpPath = shellSingleQuote(profile.wpRootPath)
                let baseCommand =
                    "wp --path=\(wpPath) media regenerate \(attachmentId) --only-missing --yes"
                let command = wrapWithOptionalTimeout(command: baseCommand, seconds: 600)
                _ = try await transport.runSSH(
                    profile: profile,
                    auth: auth,
                    remoteCommand: command,
                    writer: writer,
                    onLine: lineLogger(writer: writer)
                )

                updateFile(jobID: jobID, id: file.id) {
                    $0.status = .regenerated
                    $0.errorMessage = nil
                }
            } catch {
                updateFile(jobID: jobID, id: file.id) {
                    $0.status = .failed
                    $0.errorMessage = error.localizedDescription
                }
            }
        }

        mutateJob(id: jobID) { mutable in
            mutable.activeFileId = nil
        }
    }

    private func cleanupRemoteFiles(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter,
        jobID: UUID
    ) async {
        guard let job = jobSnapshot(id: jobID) else { return }

        let command = "rm -rf \(shellSingleQuote(job.remoteJobDir))"
        do {
            _ = try await transport.runSSH(
                profile: profile,
                auth: auth,
                remoteCommand: command,
                writer: writer,
                onLine: lineLogger(writer: writer)
            )
        } catch {
            appendLog("Remote cleanup skipped: \(error.localizedDescription)", writer: writer)
        }
    }

    // MARK: - File preparation & validation

    func prepareFileItems(urls: [URL]) throws -> [FileItem] {
        guard !urls.isEmpty else {
            throw JobRunnerError.missingFiles
        }

        let supported = urls.filter(isSupportedImageExtension)
        guard !supported.isEmpty else {
            throw JobRunnerError.unsupportedImages
        }

        var items: [FileItem] = []
        for url in supported {
            if let item = FileItem.fromURL(url) {
                items.append(item)
            }
        }

        guard !items.isEmpty else {
            throw JobRunnerError.unsupportedImages
        }

        return items
    }

    func validateProfile(_ profile: ServerProfile, password: String? = nil) throws {
        if profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JobRunnerError.profileIncomplete("Host is required")
        }

        if profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JobRunnerError.profileIncomplete("Username is required")
        }

        if profile.wpRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JobRunnerError.profileIncomplete("WordPress root path is required")
        }

        if profile.remoteStagingRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw JobRunnerError.profileIncomplete("Remote staging root is required")
        }

        if profile.authType == .password {
            let effectivePassword = password ?? profileStore.loadPassword(for: profile) ?? ""
            if effectivePassword.isEmpty {
                throw JobRunnerError.profileIncomplete("Password auth selected, but no password is stored in Keychain")
            }
        }

        if let keyPath = profile.keyPath,
           !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !FileManager.default.fileExists(atPath: keyPath)
        {
            throw JobRunnerError.profileIncomplete("SSH key file not found at \(keyPath)")
        }
    }

    // MARK: - Helpers

    private func incomingDirectory(for job: Job) -> String {
        "\(ensureNoTrailingSlash(job.remoteJobDir))/incoming"
    }

    private func remoteUploadDirectory(incomingDir: String, file: FileItem) -> String {
        "\(incomingDir)/\(file.id.uuidString)"
    }

    private func remoteUploadPath(incomingDir: String, file: FileItem) -> String {
        "\(remoteUploadDirectory(incomingDir: incomingDir, file: file))/\(file.filename)"
    }

    private func updateFile(jobID: UUID, id: UUID, _ transform: (inout FileItem) -> Void) {
        mutateJob(id: jobID) { mutable in
            guard let idx = mutable.localFiles.firstIndex(where: { $0.id == id }) else { return }
            transform(&mutable.localFiles[idx])
        }
    }

    private func jobSnapshot(id: UUID) -> Job? {
        if let currentJob, currentJob.id == id {
            return currentJob
        }
        return jobStore.job(id: id)
    }

    private func mutateJob(id: UUID, _ transform: (inout Job) -> Void) {
        guard var mutable = jobSnapshot(id: id) else { return }
        transform(&mutable)
        jobStore.upsert(mutable)

        if currentJob?.id == id || activeRunJobID == id {
            currentJob = mutable
        }
    }

    private func lineLogger(writer: LogWriter?) -> (@Sendable (CommandOutputStream, String) -> Void) {
        { [weak self] stream, line in
            Task { @MainActor in
                guard let self else { return }
                self.appendLog("[\(stream == .stdout ? "out" : "err")] \(line)", writer: writer)
            }
        }
    }

    private func appendLog(_ message: String, writer: LogWriter?) {
        let line = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        logLines.append(line)
        if logLines.count > 1000 {
            logLines = Array(logLines.suffix(1000))
        }

        writer?.append(line)
    }

    private func wrapWithOptionalTimeout(command: String, seconds: Int) -> String {
        "if command -v timeout >/dev/null 2>&1; then timeout \(seconds) \(command); else \(command); fi"
    }

    private func timeoutAwareMessage(for error: Error, fallback: String) -> String {
        let description = error.localizedDescription
        if description.contains("exit code 124") {
            return "Command timed out after 10 minutes. \(fallback)"
        }
        return fallback
    }

    private func recoverInterruptedJobs() {
        let inFlightSteps: Set<JobStep> = [.preflight, .uploading, .verifying, .importing, .regenerating]

        for existing in jobStore.jobs {
            guard inFlightSteps.contains(existing.step) else { continue }

            var recovered = existing
            var hasRetryableFailure = false

            for idx in recovered.localFiles.indices {
                switch recovered.localFiles[idx].status {
                case .regenerated, .failed:
                    continue
                case .queued, .uploaded, .verified, .imported:
                    recovered.localFiles[idx].status = .failed
                    recovered.localFiles[idx].errorMessage = "Previous run was interrupted before completion."
                    hasRetryableFailure = true
                }
            }

            if hasRetryableFailure {
                recovered.step = .failed
                recovered.errorMessage = "Previous run was interrupted. Use Retry Failed."
                jobStore.upsert(recovered)
            }
        }
    }

    private func readLogLines(atPath path: String) -> [String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }

        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.isEmpty }
            .suffix(1000)
    }
}
