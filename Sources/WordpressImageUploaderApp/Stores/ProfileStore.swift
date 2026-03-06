import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.wpmediauploader.app", category: "ProfileStore")

private struct ProfilesDiskState: Codable {
    var profiles: [ServerProfile]
}

protocol SecretStoring {
    func setSecret(_ secret: String, account: String) throws
    func getSecret(account: String) throws -> String?
    func deleteSecret(account: String) throws
}

struct KeychainSecretStore: SecretStoring {
    func setSecret(_ secret: String, account: String) throws {
        try KeychainService.setSecret(secret, account: account)
    }

    func getSecret(account: String) throws -> String? {
        try KeychainService.getSecret(account: account)
    }

    func deleteSecret(account: String) throws {
        try KeychainService.deleteSecret(account: account)
    }
}

@MainActor
@Observable
final class ProfileStore {
    var profiles: [ServerProfile] = []
    var lastError: String?

    private let secretStore: any SecretStoring
    private let profilesFileURL: URL

    init(
        secretStore: any SecretStoring = KeychainSecretStore(),
        profilesFileURL: URL = AppPaths.profilesFile
    ) {
        self.secretStore = secretStore
        self.profilesFileURL = profilesFileURL
        load()
    }

    var isEmpty: Bool {
        profiles.isEmpty
    }

    func update(_ profile: ServerProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updatedProfiles = profiles
        updatedProfiles[idx] = profile

        do {
            try persistProfiles(updatedProfiles)
        } catch {
            handlePersistenceError(error)
        }
    }

    func add(_ profile: ServerProfile) {
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            update(profile)
            return
        }

        do {
            try persistProfiles(profiles + [profile])
        } catch {
            handlePersistenceError(error)
        }
    }

    @discardableResult
    func upsertProfile(
        _ profile: ServerProfile,
        password: String,
        keyPassphrase: String
    ) throws -> ServerProfile {
        let previousProfile = profiles.first(where: { $0.id == profile.id })
        let previousPassword = previousProfile.flatMap(loadPassword(for:))
        let previousKeyPassphrase = previousProfile.flatMap(loadKeyPassphrase(for:))

        var storedProfile = profile
        do {
            if profile.authType == .password {
                storedProfile = try clearingKeyPassphrase(for: storedProfile)
                if trimmed(password).isEmpty {
                    storedProfile = try clearingPassword(for: storedProfile)
                } else {
                    storedProfile = try storingPassword(password, for: storedProfile)
                }
            } else {
                storedProfile = try clearingPassword(for: storedProfile)
                if keyPassphrase.isEmpty {
                    storedProfile = try clearingKeyPassphrase(for: storedProfile)
                } else {
                    storedProfile = try storingKeyPassphrase(keyPassphrase, for: storedProfile)
                }
            }

            do {
                try persistProfiles(upserting(profile: storedProfile, into: profiles))
            } catch {
                handlePersistenceError(error)
                throw error
            }
            return storedProfile
        } catch {
            restoreSecrets(
                previousProfile: previousProfile,
                previousPassword: previousPassword,
                previousKeyPassphrase: previousKeyPassphrase,
                fallbackProfile: storedProfile
            )
            throw error
        }
    }

    func deleteProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        if let passwordAccount = profile.passwordKeychainId {
            try? secretStore.deleteSecret(account: passwordAccount)
        }
        if let keyPassphraseAccount = profile.keyPassphraseKeychainId {
            try? secretStore.deleteSecret(account: keyPassphraseAccount)
        }

        do {
            try persistProfiles(profiles.filter { $0.id != id })
        } catch {
            handlePersistenceError(error)
        }
    }

    private func storingPassword(_ password: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.passwordKeychainId ?? "profile-\(profile.id)-password"
        try secretStore.setSecret(password, account: account)
        var updated = profile
        updated.passwordKeychainId = account
        return updated
    }

    private func clearingPassword(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.passwordKeychainId else {
            return profile
        }
        try secretStore.deleteSecret(account: account)
        var updated = profile
        updated.passwordKeychainId = nil
        return updated
    }

    private func storingKeyPassphrase(_ passphrase: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.keyPassphraseKeychainId ?? "profile-\(profile.id)-key-passphrase"
        try secretStore.setSecret(passphrase, account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = account
        return updated
    }

    private func clearingKeyPassphrase(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.keyPassphraseKeychainId else {
            return profile
        }
        try secretStore.deleteSecret(account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = nil
        return updated
    }

    func loadPassword(for profile: ServerProfile) -> String? {
        guard let account = profile.passwordKeychainId else { return nil }
        return try? secretStore.getSecret(account: account)
    }

    func loadKeyPassphrase(for profile: ServerProfile) -> String? {
        guard let account = profile.keyPassphraseKeychainId else { return nil }
        return try? secretStore.getSecret(account: account)
    }

    private func persistProfiles(_ profiles: [ServerProfile]) throws {
        AppPaths.ensureDirectory(profilesFileURL.deletingLastPathComponent())
        let state = ProfilesDiskState(profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(state)
        try data.write(to: profilesFileURL, options: [.atomic])
        self.profiles = profiles
        lastError = nil
    }

    private func load() {
        let fileURL = profilesFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            profiles = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(ProfilesDiskState.self, from: data)
            profiles = decoded.profiles
        } catch {
            profiles = []
            lastError = "Profiles data could not be read and was reset. (\(error.localizedDescription))"
            logger.error("Failed to load profiles: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func upserting(profile: ServerProfile, into profiles: [ServerProfile]) -> [ServerProfile] {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            var updatedProfiles = profiles
            updatedProfiles[idx] = profile
            return updatedProfiles
        }

        return profiles + [profile]
    }

    private func restoreSecrets(
        previousProfile: ServerProfile?,
        previousPassword: String?,
        previousKeyPassphrase: String?,
        fallbackProfile: ServerProfile
    ) {
        restoreSecret(
            account: previousProfile?.passwordKeychainId ?? fallbackProfile.passwordKeychainId,
            secret: previousPassword
        )
        restoreSecret(
            account: previousProfile?.keyPassphraseKeychainId ?? fallbackProfile.keyPassphraseKeychainId,
            secret: previousKeyPassphrase
        )
    }

    private func restoreSecret(account: String?, secret: String?) {
        guard let account else { return }

        if let secret {
            try? secretStore.setSecret(secret, account: account)
        } else {
            try? secretStore.deleteSecret(account: account)
        }
    }

    private func handlePersistenceError(_ error: Error) {
        lastError = "Failed to save profiles: \(error.localizedDescription)"
        logger.error("Failed to save profiles: \(error.localizedDescription, privacy: .public)")
    }

    private func trimmed(_ value: String) -> String {
        value.trimmed
    }
}
