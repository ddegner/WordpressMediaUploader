import Foundation

enum AuthenticationType: String, Codable, CaseIterable, Identifiable, Sendable {
    case sshKey
    case password

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sshKey:
            return "SSH Key"
        case .password:
            return "Password"
        }
    }
}

struct ServerProfile: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var authType: AuthenticationType
    var keyPath: String?
    var keyPassphraseKeychainId: String?
    var passwordKeychainId: String?
    var wpRootPath: String
    var remoteStagingRoot: String
    var bwLimitKBps: Int?
    var keepRemoteFiles: Bool
    var playCompletionSoundOnCompletion: Bool

    static let `default` = ServerProfile(
        id: UUID(),
        name: "New Profile",
        host: "",
        port: 22,
        username: "",
        authType: .password,
        keyPath: nil,
        keyPassphraseKeychainId: nil,
        passwordKeychainId: nil,
        wpRootPath: "",
        remoteStagingRoot: "~/wp-media-import",
        bwLimitKBps: nil,
        keepRemoteFiles: false,
        playCompletionSoundOnCompletion: false
    )
}

extension ServerProfile {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case host
        case port
        case username
        case authType
        case keyPath
        case keyPassphraseKeychainId
        case passwordKeychainId
        case wpRootPath
        case remoteStagingRoot
        case bwLimitKBps
        case keepRemoteFiles
        case playCompletionSoundOnCompletion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(Int.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        authType = try container.decode(AuthenticationType.self, forKey: .authType)
        keyPath = try container.decodeIfPresent(String.self, forKey: .keyPath)
        keyPassphraseKeychainId = try container.decodeIfPresent(String.self, forKey: .keyPassphraseKeychainId)
        passwordKeychainId = try container.decodeIfPresent(String.self, forKey: .passwordKeychainId)
        wpRootPath = try container.decode(String.self, forKey: .wpRootPath)
        remoteStagingRoot = try container.decode(String.self, forKey: .remoteStagingRoot)
        bwLimitKBps = try container.decodeIfPresent(Int.self, forKey: .bwLimitKBps)
        keepRemoteFiles = try container.decode(Bool.self, forKey: .keepRemoteFiles)
        playCompletionSoundOnCompletion =
            try container.decodeIfPresent(Bool.self, forKey: .playCompletionSoundOnCompletion) ?? false
    }
}

enum FileItemStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case uploaded
    case verified
    case imported
    case regenerated
    case failed
}

struct FileItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var localURL: URL
    var filename: String
    var sizeBytes: Int64
    var status: FileItemStatus
    var remotePath: String?
    var importAttachmentId: Int?
    var errorMessage: String?

    init(localURL: URL, filename: String, sizeBytes: Int64) {
        self.id = UUID()
        self.localURL = localURL
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.status = .queued
    }
}

enum JobStep: String, Codable, Sendable {
    case preflight
    case uploading
    case verifying
    case importing
    case regenerating
    case finished
    case failed
    case cancelled
}

struct Job: Identifiable, Codable, Sendable {
    var id: UUID
    var profileId: UUID
    var createdAt: Date
    var remoteJobDir: String
    var localFiles: [FileItem]
    var step: JobStep
    var uploadProgress: Double
    var importProgress: Double
    var activeFileId: UUID?
    var errorMessage: String?
    var logsPath: String

    var importedIds: [Int]

    init(profileId: UUID, remoteJobDir: String, files: [FileItem], logsPath: String) {
        self.id = UUID()
        self.profileId = profileId
        self.createdAt = Date()
        self.remoteJobDir = remoteJobDir
        self.localFiles = files
        self.step = .preflight
        self.uploadProgress = 0
        self.importProgress = 0
        self.activeFileId = nil
        self.errorMessage = nil
        self.logsPath = logsPath
        self.importedIds = []
    }

    var failedCount: Int {
        localFiles.filter { $0.status == .failed }.count
    }
}

extension FileItem {
    static func fromURL(_ url: URL) -> FileItem? {
        guard url.isFileURL else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .nameKey])
            guard values.isRegularFile == true else { return nil }
            guard let name = values.name else { return nil }
            let size = Int64(values.fileSize ?? 0)
            return FileItem(localURL: url, filename: name, sizeBytes: size)
        } catch {
            return nil
        }
    }
}
