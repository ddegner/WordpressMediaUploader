import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

@MainActor
private final class ThumbnailProvider {
    static let shared = ThumbnailProvider()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: [CheckedContinuation<NSImage?, Never>]] = [:]

    private init() {
        cache.countLimit = 500
    }

    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let key = url.standardizedFileURL.path
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            if inFlight[key] != nil {
                inFlight[key, default: []].append(continuation)
                return
            }
            inFlight[key] = [continuation]

            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                let image = representation?.nsImage
                Task { @MainActor in
                    guard let self else { return }
                    if let image {
                        self.cache.setObject(image, forKey: key as NSString)
                    }
                    let continuations = self.inFlight[key] ?? []
                    self.inFlight[key] = nil
                    for continuation in continuations {
                        continuation.resume(returning: image)
                    }
                }
            }
        }
    }
}

private struct FileThumbnailIcon: View {
    @Environment(\.displayScale) private var displayScale

    let url: URL
    var size: CGFloat = 20

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(.primary.opacity(0.08))
                    }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) { @MainActor in
            image = await ThumbnailProvider.shared.thumbnail(
                for: url,
                size: CGSize(width: size, height: size),
                scale: displayScale
            )
        }
    }
}

struct ContentView: View {
    private static let sectionHeaderFont: Font = .caption.weight(.medium)

    private struct ProfileEditorDraft: Identifiable {
        let id: UUID
        var profile: ServerProfile
        var initialPassword: String?
        var initialKeyPassphrase: String?

        init(profile: ServerProfile, initialPassword: String?, initialKeyPassphrase: String?) {
            id = profile.id
            self.profile = profile
            self.initialPassword = initialPassword
            self.initialKeyPassphrase = initialKeyPassphrase
        }
    }

    private struct DisplayFile: Identifiable {
        enum Source {
            case currentJob
            case queued
        }

        let source: Source
        let item: FileItem

        var id: String {
            switch source {
            case .currentJob:
                return "job-\(item.id.uuidString)"
            case .queued:
                return "queued-\(item.id.uuidString)"
            }
        }
    }

    private enum FileProgressState {
        case queued
        case uploading
        case processing
        case processed
        case failed
    }

    @Bindable var profileStore: ProfileStore
    @Bindable var jobStore: JobStore
    @Bindable var jobRunner: JobRunner
    @Bindable var externalFileIntake: ExternalFileIntake
    @Binding var showLogPane: Bool

    @State private var droppedFiles: [URL] = []
    @State private var droppedFileItems: [FileItem] = []
    @State private var isDropTargeted = false
    @State private var profileEditorDraft: ProfileEditorDraft?
    @State private var showErrorAlert = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detailView
        }
        .toolbar { toolbarContent }
        .onAppear {
            ingestExternalFiles()
            if profileStore.isEmpty {
                presentNewProfileEditor()
            }
        }
        .onChange(of: externalFileIntake.sequence) { _, _ in
            ingestExternalFiles()
        }
        .onOpenURL { url in
            addFiles([url])
        }
        .alert("Error", isPresented: $showErrorAlert, presenting: jobRunner.errorBanner) { _ in
            Button("OK") { jobRunner.errorBanner = nil }
        } message: { error in
            Text(error)
        }
        .onChange(of: jobRunner.errorBanner) { _, newValue in
            showErrorAlert = newValue != nil
        }
        .sheet(item: $profileEditorDraft) { draft in
            ProfileEditorView(
                profile: draft.profile,
                initialPassword: draft.initialPassword,
                initialKeyPassphrase: draft.initialKeyPassphrase,
                jobRunner: jobRunner
            ) { updated, password, keyPassphrase in
                if profileStore.profiles.contains(where: { $0.id == updated.id }) {
                    profileStore.update(updated)
                } else {
                    profileStore.profiles.append(updated)
                    profileStore.setSelectedProfile(id: updated.id)
                }
                do {
                    if let password {
                        _ = try profileStore.savePassword(password, for: updated)
                    }
                    if let keyPassphrase {
                        _ = try profileStore.saveKeyPassphrase(keyPassphrase, for: updated)
                    }
                } catch {
                    jobRunner.errorBanner = "Failed to save credentials: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                ForEach(profileStore.profiles) { profile in
                    Button {
                        profileStore.setSelectedProfile(id: profile.id)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .font(.callout)
                                    .fontWeight(profile.id == profileStore.selectedProfileId ? .semibold : .regular)
                                Text(
                                    "\(profile.username)@\(profile.host)"
                                )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "server.rack")
                                .foregroundStyle(profile.id == profileStore.selectedProfileId ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit Profile…") {
                            presentProfileEditor(for: profile)
                        }

                        Button("Delete Profile", role: .destructive) {
                            deleteProfile(profile)
                        }
                        .disabled(!canDeleteProfile)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Profiles")
                        .font(Self.sectionHeaderFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        addProfileFromSidebar()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("New profile")

                    Button {
                        deleteSelectedProfile()
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Delete selected profile")
                    .disabled(!canDeleteProfile)
                }
                .textCase(nil)
            }

            Section {
                if jobStore.jobs.isEmpty {
                    Text("No jobs yet")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    ForEach(Array(jobStore.jobs.prefix(20))) { job in
                        Button {
                            jobRunner.loadJob(job)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                                HStack(spacing: 4) {
                                    statusDot(for: job.step)
                                    Text(job.step.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("• \(job.localFiles.count) files")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(jobRunner.isRunning)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Job History")
                        .font(Self.sectionHeaderFont)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") {
                        clearJobHistory()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .controlSize(.small)
                    .disabled(!canClearJobHistory)
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    private var detailView: some View {
        VStack(spacing: 0) {
            if profileStore.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "server.rack")
                } description: {
                    Text("Click + to create a profile.")
                }
            } else if profileStore.selectedProfile == nil {
                ContentUnavailableView {
                    Label("No Profile Selected", systemImage: "server.rack")
                } description: {
                    Text("Select a profile to get started.")
                }
            } else {
                VStack(spacing: 0) {
                    if let currentJob = jobRunner.currentJob {
                        jobStatusHeader(job: currentJob)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        Divider()
                    }

                    if showLogPane {
                        VSplitView {
                            filesArea
                                .frame(minHeight: 220)
                                .layoutPriority(1)

                            logViewer
                                .frame(minHeight: 120, idealHeight: 180)
                        }
                    } else {
                        filesArea
                    }
                }
            }
        }
    }

    // MARK: - Combined Files Area

    private var filesArea: some View {
        let files = filesForDisplay()
        return ZStack {
            List {
                Section {
                    ForEach(files) { file in
                        fileRow(for: file, job: jobRunner.currentJob)
                    }
                } header: {
                    HStack {
                        Text("Photos — \(files.count)")
                            .font(Self.sectionHeaderFont)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse…") { choosePhotos() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .controlSize(.small)
                        Button("Clear") { clearAllFiles() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .controlSize(.small)
                            .disabled(!canClearFiles)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                Task {
                    let urls = await loadFileURLs(from: providers)
                    await MainActor.run {
                        addFiles(urls)
                    }
                }
                return true
            }

            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("Drop photos here")
                        .font(.headline)
                    Text("JPG, PNG, WebP, TIFF, AVIF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Browse…") { choosePhotos() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding()
            }
        }
    }

    private var canClearFiles: Bool {
        !jobRunner.isRunning && (!droppedFileItems.isEmpty || jobRunner.currentJob != nil)
    }

    private func filesForDisplay() -> [DisplayFile] {
        var rows: [DisplayFile] = []
        if let job = jobRunner.currentJob {
            rows.append(contentsOf: job.localFiles.map { DisplayFile(source: .currentJob, item: $0) })
        }
        rows.append(contentsOf: droppedFileItems.map { DisplayFile(source: .queued, item: $0) })
        return rows
    }

    private func fileRow(for file: DisplayFile, job: Job?) -> some View {
        let item = file.item
        let progressState = progressState(for: file, in: job)

        return HStack(spacing: 8) {
            FileThumbnailIcon(url: item.localURL, size: 20)
            Text(item.filename)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
            perItemIndicator(for: file, state: progressState, in: job)
            Text(progressLabel(for: progressState))
                .font(.caption.monospaced())
                .foregroundStyle(progressColor(for: progressState))
        }
        .help(file.source == .queued ? "Queued for next run" : (item.errorMessage ?? ""))
    }

    private func perItemIndicator(for file: DisplayFile, state: FileProgressState, in job: Job?) -> some View {
        Group {
            switch state {
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .processed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .uploading, .processing:
                if isActivelyRunning(file, in: job) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
            case .queued:
                statusDot(for: .queued)
            }
        }
    }

    private func isActivelyRunning(_ file: DisplayFile, in job: Job?) -> Bool {
        guard file.source == .currentJob else { return false }
        guard let job, jobRunner.isRunning else { return false }
        return job.activeFileId == file.item.id
    }

    private func progressState(for file: DisplayFile, in job: Job?) -> FileProgressState {
        if file.source == .queued {
            return .queued
        }

        let status = file.item.status
        if status == .failed {
            return .failed
        }
        if status == .regenerated {
            return .processed
        }

        if isActivelyRunning(file, in: job) {
            if job?.step == .uploading {
                return .uploading
            }
            return .processing
        }

        switch status {
        case .queued:
            return .queued
        case .uploaded, .verified:
            return .processing
        case .imported:
            return jobRunner.isRunning ? .processing : .processed
        case .regenerated:
            return .processed
        case .failed:
            return .failed
        }
    }

    private func progressLabel(for state: FileProgressState) -> String {
        switch state {
        case .queued: return "queued"
        case .uploading: return "uploading"
        case .processing: return "processing"
        case .processed: return "processed"
        case .failed: return "failed"
        }
    }

    private func progressColor(for state: FileProgressState) -> Color {
        switch state {
        case .failed: return .red
        case .processed: return .green
        case .uploading, .processing: return .blue
        case .queued: return .secondary
        }
    }


    private func jobStatusHeader(job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(job.step.rawValue, systemImage: stepIcon(job.step))
                    .font(.headline)
                    .foregroundStyle(stepColor(job.step))
                Spacer()
                if jobRunner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: job.uploadProgress)
                    Text("\(Int(job.uploadProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                GridRow {
                    Text("Import")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: job.importProgress)
                    Text("\(Int(job.importProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Logs")
                    .font(Self.sectionHeaderFont)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openLogs()
                } label: {
                    Text("View Log")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Open log file")
                .disabled(jobRunner.currentJob == nil)

                Button("Copy") {
                    copyReport()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Copy report")
                .disabled(jobRunner.currentJob == nil)

                Menu("Export") {
                    Button("Export JSON…") {
                        exportReport(as: .json)
                    }
                    Button("Export CSV…") {
                        exportReport(as: .csv)
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .controlSize(.small)
                .help("Export report")
                .disabled(jobRunner.currentJob == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            let bottomID = "log-bottom"
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(jobRunner.logLines.suffix(300).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(bottomID)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: jobRunner.logLines.count) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
                .onChange(of: jobRunner.currentJob?.id) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 80)
            .background(Color(.textBackgroundColor))
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if jobRunner.isRunning {
                Button {
                    jobRunner.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .help("Stop the current job")
            } else {
                if profileStore.selectedProfile != nil, !droppedFiles.isEmpty {
                    Button {
                        startQueuedUpload()
                    } label: {
                        Label("Upload", systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .help("Upload selected photos and import to WordPress")
                }

                if jobRunner.canRetryFailed, let profile = retryProfile {
                    Button {
                        jobRunner.retryFailed(profile: profile)
                    } label: {
                        Label("Retry Failed", systemImage: "arrow.counterclockwise")
                    }
                    .help("Retry failed files")
                }
            }
        }
    }

    // MARK: - Helpers

    private var retryProfile: ServerProfile? {
        guard let job = jobRunner.currentJob else { return nil }
        return profileStore.profiles.first(where: { $0.id == job.profileId })
    }

    private var canDeleteProfile: Bool {
        profileStore.selectedProfile != nil && !jobRunner.isRunning
    }

    private var canClearJobHistory: Bool {
        !jobRunner.isRunning && !jobStore.jobs.isEmpty
    }

    private func addProfileFromSidebar() {
        presentNewProfileEditor()
    }

    private func presentNewProfileEditor() {
        var newProfile = ServerProfile.default
        newProfile.id = UUID()
        newProfile.name = "New Profile"
        profileEditorDraft = ProfileEditorDraft(
            profile: newProfile,
            initialPassword: nil,
            initialKeyPassphrase: nil
        )
    }

    private func deleteSelectedProfile() {
        guard let selected = profileStore.selectedProfile else { return }
        deleteProfile(selected)
    }

    private func deleteProfile(_ profile: ServerProfile) {
        guard !jobRunner.isRunning else { return }
        profileStore.deleteProfile(id: profile.id)
    }

    private func clearJobHistory() {
        jobRunner.clearJobHistory()
    }

    private func presentProfileEditor(for profile: ServerProfile) {
        profileEditorDraft = ProfileEditorDraft(
            profile: profile,
            initialPassword: profileStore.loadPassword(for: profile),
            initialKeyPassphrase: profileStore.loadKeyPassphrase(for: profile)
        )
    }

    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = {
            var types: [UTType] = [.jpeg, .png, .webP, .tiff]
            if let avif = UTType(filenameExtension: "avif") {
                types.append(avif)
            }
            return types
        }()

        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func addFiles(_ urls: [URL]) {
        let imageFiles = resolveImageFileURLs(from: urls)
        guard !imageFiles.isEmpty else { return }

        let existing = Set(droppedFiles.map(\.path))
        let additions = imageFiles.filter { !existing.contains($0.path) }
        droppedFiles.append(contentsOf: additions)
        droppedFileItems = droppedFiles.compactMap(FileItem.fromURL)
    }

    private func ingestExternalFiles() {
        addFiles(externalFileIntake.drain())
    }

    private func clearAllFiles() {
        guard !jobRunner.isRunning else { return }
        droppedFiles.removeAll()
        droppedFileItems.removeAll()
        jobRunner.currentJob = nil
    }

    private func startQueuedUpload() {
        guard let profile = profileStore.selectedProfile else { return }
        let queued = droppedFiles
        guard !queued.isEmpty else { return }

        jobRunner.start(profile: profile, fileURLs: queued)
        if jobRunner.isRunning {
            droppedFiles.removeAll()
            droppedFileItems.removeAll()
        }
    }

    private func copyReport() {
        let text = jobRunner.reportText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func exportReport(as format: ReportExportFormat) {
        guard let payload = jobRunner.reportPayload(format: format) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = jobRunner.suggestedReportFileName(format: format)
        panel.allowedContentTypes = [contentType(for: format)]

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try payload.write(to: destination, atomically: true, encoding: .utf8)
        } catch {
            jobRunner.errorBanner = "Failed to export: \(error.localizedDescription)"
        }
    }

    private func openLogs() {
        guard let path = jobRunner.currentJob?.logsPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func contentType(for format: ReportExportFormat) -> UTType {
        switch format {
        case .text: return .plainText
        case .json: return .json
        case .csv: return .commaSeparatedText
        }
    }

    private func statusColor(_ status: FileItemStatus) -> Color {
        switch status {
        case .failed: return .red
        case .regenerated: return .green
        case .imported, .verified, .uploaded: return .blue
        case .queued: return .secondary
        }
    }

    private func statusDot(for status: FileItemStatus) -> some View {
        Circle()
            .fill(statusColor(status))
            .frame(width: 8, height: 8)
    }

    private func statusDot(for step: JobStep) -> some View {
        Circle()
            .fill(stepColor(step))
            .frame(width: 8, height: 8)
    }

    private func stepColor(_ step: JobStep) -> Color {
        switch step {
        case .finished: return .green
        case .failed, .cancelled: return .red
        default: return .accentColor
        }
    }

    private func stepIcon(_ step: JobStep) -> String {
        switch step {
        case .preflight: return "network"
        case .uploading: return "arrow.up.circle"
        case .verifying: return "checkmark.shield"
        case .importing: return "square.and.arrow.down"
        case .regenerating: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()
}
