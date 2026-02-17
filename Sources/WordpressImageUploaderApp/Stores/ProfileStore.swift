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

    func update(_ profile: ServerProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
    }

    func add(_ profile: ServerProfile) {
        guard !profiles.contains(where: { $0.id == profile.id }) else {
            update(profile)
            return
        }
        profiles.append(profile)
        save()
    }

    @discardableResult
    func upsertProfile(
        _ profile: ServerProfile,
        password: String,
        keyPassphrase: String
    ) throws -> ServerProfile {
        if profiles.contains(where: { $0.id == profile.id }) {
            update(profile)
        } else {
            add(profile)
        }

        var storedProfile = profile
        if profile.authType == .password {
            storedProfile = try clearKeyPassphrase(for: storedProfile)
            if trimmed(password).isEmpty {
                storedProfile = try clearPassword(for: storedProfile)
            } else {
                storedProfile = try savePassword(password, for: storedProfile)
            }
        } else {
            storedProfile = try clearPassword(for: storedProfile)
            if keyPassphrase.isEmpty {
                storedProfile = try clearKeyPassphrase(for: storedProfile)
            } else {
                storedProfile = try saveKeyPassphrase(keyPassphrase, for: storedProfile)
            }
        }

        return storedProfile
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

    func savePassword(_ password: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.passwordKeychainId ?? "profile-\(profile.id)-password"
        try KeychainService.setSecret(password, account: account)
        var updated = profile
        updated.passwordKeychainId = account
        update(updated)
        return updated
    }

    func clearPassword(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.passwordKeychainId else {
            return profile
        }
        try KeychainService.deleteSecret(account: account)
        var updated = profile
        updated.passwordKeychainId = nil
        update(updated)
        return updated
    }

    func saveKeyPassphrase(_ passphrase: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.keyPassphraseKeychainId ?? "profile-\(profile.id)-key-passphrase"
        try KeychainService.setSecret(passphrase, account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = account
        update(updated)
        return updated
    }

    func clearKeyPassphrase(for profile: ServerProfile) throws -> ServerProfile {
        guard let account = profile.keyPassphraseKeychainId else {
            return profile
        }
        try KeychainService.deleteSecret(account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = nil
        update(updated)
        return updated
    }

    func loadPassword(for profile: ServerProfile) -> String? {
        guard let account = profile.passwordKeychainId else { return nil }
        return try? KeychainService.getSecret(account: account)
    }

    func loadKeyPassphrase(for profile: ServerProfile) -> String? {
        guard let account = profile.keyPassphraseKeychainId else { return nil }
        return try? KeychainService.getSecret(account: account)
    }

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

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
