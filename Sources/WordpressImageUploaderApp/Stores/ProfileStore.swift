import Foundation
import Observation

private struct ProfilesDiskState: Codable {
    var profiles: [ServerProfile]
    var selectedProfileId: UUID?
}

@MainActor
@Observable
final class ProfileStore {
    var profiles: [ServerProfile] = []
    var selectedProfileId: UUID?

    init() {
        load()
        if profiles.isEmpty {
            let profile = ServerProfile.default
            profiles = [profile]
            selectedProfileId = profile.id
            save()
        } else if selectedProfileId == nil {
            selectedProfileId = profiles.first?.id
            save()
        }
    }

    var selectedProfile: ServerProfile? {
        guard let selectedProfileId else { return nil }
        return profiles.first { $0.id == selectedProfileId }
    }

    func addNewProfile() {
        var base = ServerProfile.default
        base.id = UUID()
        base.name = uniqueProfileName(base: "Profile")
        profiles.append(base)
        selectedProfileId = base.id
        save()
    }

    func update(_ profile: ServerProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        save()
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
        if selectedProfileId == id {
            selectedProfileId = profiles.first?.id
        }
        save()
    }

    func setSelectedProfile(id: UUID?) {
        selectedProfileId = id
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

    func saveKeyPassphrase(_ passphrase: String, for profile: ServerProfile) throws -> ServerProfile {
        let account = profile.keyPassphraseKeychainId ?? "profile-\(profile.id)-key-passphrase"
        try KeychainService.setSecret(passphrase, account: account)
        var updated = profile
        updated.keyPassphraseKeychainId = account
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

    private func uniqueProfileName(base: String) -> String {
        let existing = Set(profiles.map(\.name))
        if !existing.contains(base) {
            return base
        }

        var idx = 2
        while existing.contains("\(base) \(idx)") {
            idx += 1
        }
        return "\(base) \(idx)"
    }

    private func save() {
        let state = ProfilesDiskState(profiles: profiles, selectedProfileId: selectedProfileId)
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
            selectedProfileId = decoded.selectedProfileId
        } catch {
            profiles = []
            selectedProfileId = nil
        }
    }
}
