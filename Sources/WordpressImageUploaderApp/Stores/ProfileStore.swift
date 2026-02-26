import Foundation
import Observation

private struct ProfilesDiskState: Codable {
    var profiles: [ServerProfile]
}

@MainActor
@Observable
final class ProfileStore {
    var profiles: [ServerProfile] = []

    init() {
        load()
    }

    var isEmpty: Bool {
        profiles.isEmpty
    }

    @discardableResult
    func upsertProfile(
        _ profile: ServerProfile,
        password: String,
        keyPassphrase: String
    ) throws -> ServerProfile {
        var stored = profile

        if profile.authType == .password {
            stored = try applyKeyPassphraseClear(for: stored)
            if password.trimmed.isEmpty {
                stored = try applyPasswordClear(for: stored)
            } else {
                stored = try applyPasswordSave(password, for: stored)
            }
        } else {
            stored = try applyPasswordClear(for: stored)
            if keyPassphrase.isEmpty {
                stored = try applyKeyPassphraseClear(for: stored)
            } else {
                stored = try applyKeyPassphraseSave(keyPassphrase, for: stored)
            }
        }

        if let idx = profiles.firstIndex(where: { $0.id == stored.id }) {
            profiles[idx] = stored
        } else {
            profiles.append(stored)
        }
        save()

        return stored
    }

    func deleteProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }

        if let passwordAccount = profile.passwordKeychainId {
            try? KeychainService.deleteSecret(account: passwordAccount)
        }
        if let keyPassphraseAccount = profile.keyPassphraseKeychainId {
            try? KeychainService.deleteSecret(account: keyPassphraseAccount)
        }

        profiles.removeAll { $0.id == id }
        save()
    }

    func loadPassword(for profile: ServerProfile) -> String? {
        guard let account = profile.passwordKeychainId else { return nil }
        return try? KeychainService.getSecret(account: account)
    }

    func loadKeyPassphrase(for profile: ServerProfile) -> String? {
        guard let account = profile.keyPassphraseKeychainId else { return nil }
        return try? KeychainService.getSecret(account: account)
    }

    // MARK: - Credential helpers (mutate profile in memory, no disk write)

    private func applyPasswordSave(_ password: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.passwordKeychainId ?? "profile-\(profile.id)-password"
        try KeychainService.setSecret(password, account: account)
        var updated = profile
        updated.passwordKeychainId = account
        return updated
    }

    private func applyPasswordClear(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.passwordKeychainId else { return profile }
        try KeychainService.deleteSecret(account: account)
        var updated = profile
        updated.passwordKeychainId = nil
        return updated
    }

    private func applyKeyPassphraseSave(_ passphrase: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.keyPassphraseKeychainId ?? "profile-\(profile.id)-key-passphrase"
        try KeychainService.setSecret(passphrase, account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = account
        return updated
    }

    private func applyKeyPassphraseClear(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.keyPassphraseKeychainId else { return profile }
        try KeychainService.deleteSecret(account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = nil
        return updated
    }

    // MARK: - Persistence

    private func save() {
        let state = ProfilesDiskState(profiles: profiles)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(state)
            try data.write(to: AppPaths.profilesFile, options: [.atomic])
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: AppPaths.profilesFile)
            let decoded = try JSONDecoder().decode(ProfilesDiskState.self, from: data)
            profiles = decoded.profiles
        } catch {
            profiles = []
        }
    }
}
