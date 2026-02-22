import Foundation

struct SSHAuthContext: Sendable {
    var additionalSSHArgs: [String]
    var environment: [String: String]?
    var askPassScriptURL: URL?

    func cleanup() {
        guard let askPassScriptURL else { return }
        try? FileManager.default.removeItem(at: askPassScriptURL)
    }
}

struct ProfileTestResult: Sendable {
    var checks: [String]
    var success: Bool
}

@MainActor
final class SSHTransport {
    private let commandRunner = CommandRunner()
    private let profileStore: ProfileStore
    private var knownHostsPathCache: String?
    private var didCleanupStaleAskPassScripts = false

    init(profileStore: ProfileStore) {
        self.profileStore = profileStore
    }

    // MARK: - Stale askpass cleanup (B1)

    private func cleanupStaleAskPassScripts() {
        let fm = FileManager.default
        for directory in askPassDirectories() {
            guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }

            for filename in contents where filename.hasPrefix("askpass-") && filename.hasSuffix(".sh") {
                let fullPath = directory.appendingPathComponent(filename, isDirectory: false).path
                try? fm.removeItem(atPath: fullPath)
            }
        }
    }

    private func cleanupStaleAskPassScriptsIfNeeded() {
        guard !didCleanupStaleAskPassScripts else { return }
        didCleanupStaleAskPassScripts = true
        cleanupStaleAskPassScripts()
    }

    // MARK: - Auth context

    func makeAuthContext(for profile: ServerProfile) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: profileStore.loadPassword(for: profile),
            keyPassphrase: profileStore.loadKeyPassphrase(for: profile),
            passwordMissingDetail: "Password auth selected, but no password is stored in Keychain"
        )
    }

    func makeAuthContext(for profile: ServerProfile, password: String?, keyPassphrase: String?) throws -> SSHAuthContext {
        try makeAuthContext(
            for: profile,
            password: password,
            keyPassphrase: keyPassphrase,
            passwordMissingDetail: "Password auth selected, but no password provided"
        )
    }

    // MARK: - Auth context (private)

    private func makeAuthContext(
        for profile: ServerProfile,
        password: String?,
        keyPassphrase: String?,
        passwordMissingDetail: String
    ) throws -> SSHAuthContext {
        cleanupStaleAskPassScriptsIfNeeded()

        switch profile.authType {
        case .sshKey:
            var args: [String] = []
            if let keyPath = profile.keyPath,
               !keyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                args += ["-i", keyPath]
            }

            if let passphrase = keyPassphrase, !passphrase.isEmpty {
                let scriptURL = try createAskPassScript(secret: passphrase)
                args = [
                    "-o", "BatchMode=no"
                ] + args

                let env = [
                    "SSH_ASKPASS": scriptURL.path,
                    "SSH_ASKPASS_REQUIRE": "force",
                    "DISPLAY": "1"
                ]
                return SSHAuthContext(additionalSSHArgs: args, environment: env, askPassScriptURL: scriptURL)
            }

            args = [
                "-o", "BatchMode=yes"
            ] + args
            return SSHAuthContext(additionalSSHArgs: args, environment: nil, askPassScriptURL: nil)

        case .password:
            guard let password, !password.isEmpty else {
                throw JobRunnerError.profileIncomplete(passwordMissingDetail)
            }
            let scriptURL = try createAskPassScript(secret: password)

            let args = [
                "-o", "BatchMode=no",
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1"
            ]

            let env = [
                "SSH_ASKPASS": scriptURL.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "1"
            ]

            return SSHAuthContext(additionalSSHArgs: args, environment: env, askPassScriptURL: scriptURL)
        }
    }

    // MARK: - SSH execution

    func runSSH(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remoteCommand: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> CommandResult {
        let args = sshBaseArgs(profile: profile, auth: auth) + [remoteCommand]
        writer?.append("$ /usr/bin/ssh \(args.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: args,
            environment: auth.environment,
            currentDirectoryURL: nil,
            displayName: "ssh"
        )

        let result = try await commandRunner.run(spec, onLine: onLine)

        guard result.exitCode == 0 else {
            let tail = result.stderrLines.suffix(3).joined(separator: " | ")
            throw CommandRunnerError.nonZeroExit(code: result.exitCode, stderrTail: tail)
        }

        return result
    }

    // MARK: - Rsync execution

    func runRsyncFile(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        remoteTargetPath: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        var arguments = makeRsyncArguments(
            profile: profile,
            auth: auth,
            localFileURL: localFileURL,
            remoteTargetPath: remoteTargetPath,
            progressMode: .preferred
        )

        let firstAttempt = try await runRsync(
            arguments: arguments,
            environment: auth.environment,
            writer: writer,
            onLine: onLine
        )

        if firstAttempt.exitCode == 0 {
            return
        }

        if shouldFallbackForRsyncCompatibility(firstAttempt.stderrLines) {
            writer?.append("rsync compatibility fallback: retrying with --append --progress")
            arguments = makeRsyncArguments(
                profile: profile,
                auth: auth,
                localFileURL: localFileURL,
                remoteTargetPath: remoteTargetPath,
                progressMode: .compatible
            )

            let secondAttempt = try await runRsync(
                arguments: arguments,
                environment: auth.environment,
                writer: writer,
                onLine: onLine
            )

            guard secondAttempt.exitCode == 0 else {
                let stderrTail = secondAttempt.stderrLines.suffix(3).joined(separator: " | ")
                throw CommandRunnerError.nonZeroExit(code: secondAttempt.exitCode, stderrTail: stderrTail)
            }
            return
        }

        let stderrTail = firstAttempt.stderrLines.suffix(3).joined(separator: " | ")
        throw CommandRunnerError.nonZeroExit(code: firstAttempt.exitCode, stderrTail: stderrTail)
    }

    // MARK: - Remote helpers

    func fetchRemoteHomeDirectory(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> String {
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "printf '%s' \"$HOME\"",
            writer: writer,
            onLine: onLine
        )
        let home = result.stdoutLines.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if home.isEmpty {
            throw JobRunnerError.profileIncomplete("Could not resolve remote $HOME path")
        }
        return home
    }

    func fetchRemoteFileSize(
        profile: ServerProfile,
        auth: SSHAuthContext,
        remotePath: String,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws -> Int64 {
        let command = "(stat -c%s \(shellSingleQuote(remotePath)) 2>/dev/null || stat -f%z \(shellSingleQuote(remotePath)) 2>/dev/null)"
        let result = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: command,
            writer: writer,
            onLine: onLine
        )

        guard let line = result.stdoutLines
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .last,
              let value = Int64(line)
        else {
            throw JobRunnerError.profileIncomplete("Could not parse remote file size for \(remotePath)")
        }

        return value
    }

    // MARK: - Shared preflight checks (S6)

    func runPreflightChecks(
        profile: ServerProfile,
        auth: SSHAuthContext,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)? = nil
    ) async throws {
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "uname -a",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v wp",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "command -v rsync",
            writer: writer,
            onLine: onLine
        )
        _ = try await runSSH(
            profile: profile,
            auth: auth,
            remoteCommand: "wp --path=\(shellSingleQuote(profile.wpRootPath)) core is-installed",
            writer: writer,
            onLine: onLine
        )
    }

    func cancelActiveProcess() async {
        await commandRunner.cancelActiveProcess()
    }

    // MARK: - Private helpers

    func sshBaseArgs(profile: ServerProfile, auth: SSHAuthContext) -> [String] {
        var args = [
            "-p", "\(profile.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1"
        ]
        if let knownHostsPath = knownHostsPath() {
            args += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        }
        args += auth.additionalSSHArgs
        args.append("\(profile.username)@\(profile.host)")
        return args
    }

    private func rsyncSSHTransport(profile: ServerProfile, auth: SSHAuthContext) -> String {
        var parts = [
            "ssh",
            "-p", "\(profile.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1"
        ]
        if let knownHostsPath = knownHostsPath() {
            parts += ["-o", "UserKnownHostsFile=\(knownHostsPath)"]
        }
        parts += auth.additionalSSHArgs
        return parts.map(shellSingleQuote).joined(separator: " ")
    }

    private enum RsyncProgressMode {
        case preferred
        case compatible
    }

    private func makeRsyncArguments(
        profile: ServerProfile,
        auth: SSHAuthContext,
        localFileURL: URL,
        remoteTargetPath: String,
        progressMode: RsyncProgressMode
    ) -> [String] {
        var arguments = ["-az", "--partial"]

        switch progressMode {
        case .preferred:
            arguments += ["--append-verify", "--info=progress2"]
        case .compatible:
            arguments += ["--append", "--progress"]
        }

        arguments += ["-e", rsyncSSHTransport(profile: profile, auth: auth)]
        arguments.append(localFileURL.path)
        arguments.append("\(profile.username)@\(profile.host):\(shellSingleQuote(remoteTargetPath))")
        return arguments
    }

    private func runRsync(
        arguments: [String],
        environment: [String: String]?,
        writer: LogWriter?,
        onLine: (@Sendable (CommandOutputStream, String) -> Void)?
    ) async throws -> CommandResult {
        writer?.append("$ /usr/bin/rsync \(arguments.joined(separator: " "))")

        let spec = CommandSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/rsync"),
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: nil,
            displayName: "rsync"
        )
        return try await commandRunner.run(spec, onLine: onLine)
    }

    private func shouldFallbackForRsyncCompatibility(_ stderrLines: [String]) -> Bool {
        let stderr = stderrLines.joined(separator: "\n").lowercased()
        let unknownOption = stderr.contains("unrecognized option") || stderr.contains("unknown option")
        guard unknownOption else { return false }
        return stderr.contains("append-verify") || stderr.contains("info=progress2")
    }

    private func createAskPassScript(secret: String) throws -> URL {
        let scriptDirectory = askPassDirectory()
        AppPaths.ensureDirectory(scriptDirectory)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptDirectory.path)

        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectoryURL = scriptDirectory
        try? mutableDirectoryURL.setResourceValues(directoryValues)

        let scriptURL = scriptDirectory.appendingPathComponent(
            "askpass-\(UUID().uuidString).sh",
            isDirectory: false
        )

        let script = """
        #!/bin/sh
        printf '%s\\n' \(shellSingleQuote(secret))
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            var fileValues = URLResourceValues()
            fileValues.isExcludedFromBackup = true
            var mutableScriptURL = scriptURL
            try? mutableScriptURL.setResourceValues(fileValues)
            return scriptURL
        } catch {
            throw JobRunnerError.authSetupFailed(error.localizedDescription)
        }
    }

    private func askPassDirectories() -> [URL] {
        [
            AppPaths.appSupportDirectory,
            askPassDirectory()
        ]
    }

    private func askPassDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WPMediaUploader", isDirectory: true)
            .appendingPathComponent("askpass", isDirectory: true)
    }

    private func knownHostsPath() -> String? {
        if let knownHostsPathCache {
            return knownHostsPathCache
        }

        let knownHostsFileURL = AppPaths.appSupportDirectory
            .appendingPathComponent("known_hosts", isDirectory: false)
        let fileManager = FileManager.default
        let parent = knownHostsFileURL.deletingLastPathComponent()
        AppPaths.ensureDirectory(parent)

        if !fileManager.fileExists(atPath: knownHostsFileURL.path) {
            fileManager.createFile(atPath: knownHostsFileURL.path, contents: Data())
        }

        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownHostsFileURL.path)
        knownHostsPathCache = knownHostsFileURL.path
        return knownHostsPathCache
    }
}

// MARK: - Shared utilities used by JobRunner

func resolvedStagingRoot(profile: ServerProfile, homeDirectory: String) -> String {
    if profile.remoteStagingRoot == "~" {
        return homeDirectory
    }

    if profile.remoteStagingRoot.hasPrefix("~/") {
        let suffix = String(profile.remoteStagingRoot.dropFirst(2))
        return "\(homeDirectory)/\(suffix)"
    }

    return profile.remoteStagingRoot
}
