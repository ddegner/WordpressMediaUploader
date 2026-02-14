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

    static let `default` = ServerProfile(
        id: UUID(),
        name: "New Profile",
        host: "",
        port: 22,
        username: "",
        authType: .sshKey,
        keyPath: nil,
        keyPassphraseKeychainId: nil,
        passwordKeychainId: nil,
        wpRootPath: "",
        remoteStagingRoot: "~/wp-media-import",
        bwLimitKBps: nil,
        keepRemoteFiles: false
    )
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

    var completedCount: Int {
        localFiles.filter { $0.status == .regenerated }.count
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
