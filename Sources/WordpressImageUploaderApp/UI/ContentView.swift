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
        let key = cacheKey(for: url, size: size, scale: scale)
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

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [key] representation, _ in
                let image = representation?.nsImage
                Task { @MainActor in
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

    private func cacheKey(for url: URL, size: CGSize, scale: CGFloat) -> String {
        let pxWidth = Int((size.width * scale).rounded())
        let pxHeight = Int((size.height * scale).rounded())
        return "\(url.standardizedFileURL.path)|\(pxWidth)x\(pxHeight)"
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

private extension Color {
    init(hexRGB: UInt32) {
        let red = Double((hexRGB >> 16) & 0xFF) / 255.0
        let green = Double((hexRGB >> 8) & 0xFF) / 255.0
        let blue = Double(hexRGB & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}

struct ContentView: View {
    private static let profilesDrawerWidth: CGFloat = 260
    private static let operationsDrawerWidth: CGFloat = 320
    private static let workbenchMinWidth: CGFloat = 180
    private static let drawerTransitionDuration: TimeInterval = 0.24
    private static let visibleLogLineLimit = 300

    private static let sectionHeaderFont: Font = .caption2.weight(.semibold)
    private static let editorBackground = Color(nsColor: .textBackgroundColor)
    private static let chromeBackground = Color(nsColor: .windowBackgroundColor)


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

    @Bindable var profileStore: ProfileStore
    @Bindable var jobStore: JobStore
    @Bindable var jobRunner: JobRunner
    @Bindable var externalFileIntake: ExternalFileIntake

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlActiveState) private var controlActiveState

    @State private var droppedFileItems: [FileItem] = []
    @State private var isDropTargeted = false
    @State private var selectedFileRowIDs: Set<String> = []
    @State private var profileEditorDraft: ProfileEditorDraft?
    @State private var showBlockingErrorAlert = false
    @State private var selectedProfileId: UUID?
    @State private var rightPane: WorkspaceOperationsTab?
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all
    @State private var runtimeAnchors: [UUID: JobRuntimeAnchor] = [:]

    private var selectedProfile: ServerProfile? {
        guard let selectedProfileId else { return nil }
        return profileStore.profiles.first { $0.id == selectedProfileId }
    }

    private var drawerTransitionTime: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : Self.drawerTransitionDuration
    }

    private var drawerTransitionAnimation: Animation {
        .easeInOut(duration: drawerTransitionTime)
    }

    private var isProfilesDrawerVisible: Bool {
        WorkspaceLayoutState.profilesDrawerVisible(for: splitViewVisibility)
    }

    private var isOperationsDrawerVisible: Bool {
        rightPane != nil
    }

    private var activeOperationsTab: WorkspaceOperationsTab {
        rightPane ?? .activeJob
    }

    private var profilesDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { isProfilesDrawerVisible },
            set: { setProfilesDrawerVisible($0) }
        )
    }

    private var operationsDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { isOperationsDrawerVisible },
            set: { setOperationsDrawerVisible($0) }
        )
    }

    private var operationsTabBinding: Binding<WorkspaceOperationsTab> {
        Binding(
            get: { activeOperationsTab },
            set: { selectOperationsPane($0) }
        )
    }

    private var visibleDrawerWidth: CGFloat {
        (isProfilesDrawerVisible ? Self.profilesDrawerWidth : 0)
            + (isOperationsDrawerVisible ? Self.operationsDrawerWidth : 0)
    }

    private var minimumWindowWidth: CGFloat {
        visibleDrawerWidth + Self.workbenchMinWidth
    }

    private var drawerBackground: Color {
        switch colorScheme {
        case .dark:
            return Color(hexRGB: isWindowFocused ? 0x2A2A2C : 0x303033)
        case .light:
            return Color(hexRGB: isWindowFocused ? 0xF8F8F8 : 0xF4F4F4)
        @unknown default:
            return Color(hexRGB: isWindowFocused ? 0xF8F8F8 : 0xF4F4F4)
        }
    }

    private var isWindowFocused: Bool {
        controlActiveState != .inactive
    }

    var body: some View {
        workspacePresentationLayer
            .alert("Error", isPresented: $showBlockingErrorAlert, presenting: jobRunner.blockingError) { _ in
                Button("OK") { jobRunner.blockingError = nil }
            } message: { error in
                Text(error)
            }
            .onChange(of: jobRunner.blockingError) { _, newValue in
                showBlockingErrorAlert = newValue != nil
            }
            .sheet(item: $profileEditorDraft) { draft in
                ProfileEditorView(
                    profile: draft.profile,
                    initialPassword: draft.initialPassword,
                    initialKeyPassphrase: draft.initialKeyPassphrase,
                    jobRunner: jobRunner
                ) { updated, password, keyPassphrase in
                    let isNewProfile = !profileStore.profiles.contains(where: { $0.id == updated.id })
                    if isNewProfile {
                        selectedProfileId = updated.id
                    }

                    do {
                        _ = try profileStore.upsertProfile(
                            updated,
                            password: password,
                            keyPassphrase: keyPassphrase
                        )
                    } catch {
                        jobRunner.blockingError = "Failed to save credentials: \(error.localizedDescription)"
                    }
                }
            }
    }

    private var workspacePresentationLayer: some View {
        workspaceLifecycleLayer
            .frame(minWidth: minimumWindowWidth, minHeight: 600)
            .background(Self.editorBackground)
            .focusedSceneValue(\.showProfilesDrawerBinding, profilesDrawerSceneBinding)
            .focusedSceneValue(\.showOperationsDrawerBinding, operationsDrawerSceneBinding)
            .focusedSceneValue(\.windowCommandActions, windowCommandActions)
    }

    private var workspaceLifecycleLayer: some View {
        workspaceContainer
            .onAppear {
                splitViewVisibility = WorkspaceLayoutState.splitVisibility(forProfilesDrawer: true)
                rightPane = rightPane ?? .activeJob
                ingestExternalFiles()
                seedRuntimeAnchorForActiveJob(force: true)
                if selectedProfileId == nil {
                    selectedProfileId = profileStore.profiles.first?.id
                }
                if profileStore.isEmpty {
                    presentNewProfileEditor()
                }
            }
            .onChange(of: externalFileIntake.sequence) { _, _ in
                ingestExternalFiles()
            }
            .onChange(of: jobRunner.isRunning) { _, running in
                if running {
                    seedRuntimeAnchorForActiveJob(force: true)
                }
            }
            .onChange(of: jobRunner.currentJob?.id) { _, _ in
                seedRuntimeAnchorForActiveJob(force: true)
            }
            .onChange(of: jobRunner.currentJob?.step) { _, step in
                guard step == .preflight else { return }
                seedRuntimeAnchorForActiveJob(force: true)
            }
            .onChange(of: profileStore.profiles.map(\.id)) { _, ids in
                if let selectedProfileId, !ids.contains(selectedProfileId) {
                    self.selectedProfileId = ids.first
                } else if self.selectedProfileId == nil {
                    self.selectedProfileId = ids.first
                }
            }
            .onOpenURL { url in
                addFiles([url])
            }
    }

    private var workspaceContainer: some View {
        HStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $splitViewVisibility) {
                sidebar
                    .navigationSplitViewColumnWidth(
                        min: Self.profilesDrawerWidth,
                        ideal: Self.profilesDrawerWidth,
                        max: Self.profilesDrawerWidth
                    )
                    .background(drawerBackground)
            } detail: {
                middleWorkbench
                    .frame(minWidth: Self.workbenchMinWidth, maxWidth: .infinity)
                    .background(Self.editorBackground)
                    .toolbar {
                        middleToolbarItems()
                    }
            }
            .toolbarRole(.editor)
            .navigationSplitViewStyle(.balanced)

            if isOperationsDrawerVisible {
                operationsDrawer
                    .frame(width: Self.operationsDrawerWidth)
                    .background(drawerBackground)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(drawerTransitionAnimation, value: isOperationsDrawerVisible)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedProfileId) {
                Section {
                    ForEach(profileStore.profiles) { profile in
                        profileSidebarRow(profile)
                            .tag(profile.id)
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
                    Text("PROFILES")
                        .font(Self.sectionHeaderFont)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(drawerBackground)
            .environment(\.defaultMinListRowHeight, 30)

            HStack(spacing: 8) {
                paneHeaderButton(systemImage: "plus", help: "New profile") {
                    presentNewProfileEditor()
                }
                paneHeaderButton(
                    systemImage: "minus",
                    help: "Delete selected profile",
                    isDisabled: !canDeleteProfile
                ) {
                    if let selectedProfile {
                        deleteProfile(selectedProfile)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(drawerBackground)
        }
    }

    private func profileSidebarRow(_ profile: ServerProfile) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.callout)
                Text("\(profile.username)@\(profile.host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } icon: {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Middle Workbench

    private var middleWorkbench: some View {
        VStack(spacing: 0) {
            if selectedProfile != nil {
                filesArea
            } else if profileStore.isEmpty {
                ContentUnavailableView {
                    Label("No Profiles", systemImage: "server.rack")
                } description: {
                    Text("Create a profile to start uploading.")
                } actions: {
                    Button("Create Profile") {
                        presentNewProfileEditor()
                    }
                    if !isProfilesDrawerVisible {
                        Button("Open Profiles Drawer") {
                            setProfilesDrawerVisible(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Profile Selected", systemImage: "server.rack")
                } description: {
                    Text("Select a profile to get started.")
                } actions: {
                    if !isProfilesDrawerVisible {
                        Button("Open Profiles Drawer") {
                            setProfilesDrawerVisible(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Self.editorBackground)
    }

    @ToolbarContentBuilder
    private func middleToolbarItems() -> some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            toolbarProfileLabel
        }

        ToolbarItemGroup(placement: .automatic) {
            Button {
                clearAllFiles()
            } label: {
                Label("Reset", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .disabled(!canResetAction)
            .help("Reset queued files and clear the current job")
            .accessibilityLabel("Reset queued files and clear the current job")

            Button {
                guard let profile = retryProfile else { return }
                jobRunner.retryFailed(profile: profile)
            } label: {
                Label("Retry Failed", systemImage: "arrow.counterclockwise")
            }
            .labelStyle(.iconOnly)
            .disabled(!(jobRunner.canRetryFailed && retryProfile != nil))
            .help("Retry failed or unfinished files; successful files are skipped")
            .accessibilityLabel("Retry failed or unfinished files; successful files are skipped")

            Button {
                jobRunner.cancel()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(!canStopAction)
            .help("Stop all active transfers in this window")
            .accessibilityLabel("Stop all active transfers in this window")

            Button {
                startQueuedUpload()
            } label: {
                Label("Start Upload", systemImage: "play.fill")
            }
            .labelStyle(.iconOnly)
            .disabled(!canStartAction)
            .help("Upload selected photos and import to WordPress")
            .accessibilityLabel("Upload selected photos and import to WordPress")
            .keyboardShortcut(.defaultAction)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Spacer()

            Button {
                setOperationsDrawerVisible(!isOperationsDrawerVisible)
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .help(isOperationsDrawerVisible ? "Hide operations drawer" : "Show operations drawer")
        }
    }

    private var toolbarProfileLabel: some View {
        Group {
            if let selectedProfile {
                VStack(alignment: .leading, spacing: 1) {
                    Text(selectedProfile.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(selectedProfile.username)@\(selectedProfile.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help("\(selectedProfile.username)@\(selectedProfile.host)")
            } else if profileStore.isEmpty {
                Text("No Profiles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text("No Profile Selected")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(maxWidth: 340, alignment: .leading)
    }

    // MARK: - Operations Drawer

    private var operationsDrawer: some View {
        VStack(spacing: 0) {
            Picker("Operations", selection: operationsTabBinding) {
                ForEach(WorkspaceOperationsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(drawerBackground)

            Group {
                switch activeOperationsTab {
                case .activeJob:
                    VStack(spacing: 0) {
                        operationsProgressPanel
                        Spacer(minLength: 0)
                    }
                case .terminal:
                    logViewer
                case .history:
                    jobHistoryView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(drawerBackground)
    }

    private var operationsProgressPanel: some View {
        VStack(spacing: 0) {
            operationsPanelHeader("ACTIVE JOB")

            if let job = jobRunner.currentJob {
                VStack(alignment: .leading, spacing: 8) {
                    jobStatusHeader(job: job)

                    if let message = operationsInlineMessage {
                        inlineMessageRow(message: message)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else {
                operationsEmptyState("No job selected")
            }
        }
        .background(drawerBackground)
    }

    private func operationsEmptyState(_ message: String) -> some View {
        VStack {
            Spacer(minLength: 0)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(drawerBackground)
    }

    private var terminalContent: some View {
        let bottomID = "log-bottom"

        return Group {
            if jobRunner.logLines.isEmpty {
                operationsEmptyState("No job selected")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(jobRunner.logLines.suffix(Self.visibleLogLineLimit).enumerated()), id: \.offset) { _, line in
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
            }
        }
        .frame(minHeight: 80)
        .background(drawerBackground)
    }

    private var operationsInlineMessage: String? {
        if let message = jobRunner.inlineStatusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            return message
        }

        guard let currentJob = jobRunner.currentJob else { return nil }
        guard currentJob.step == .failed || currentJob.step == .cancelled else { return nil }
        return currentJob.errorMessage
    }

    private func inlineMessageRow(message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    private var selectedProfileJobs: [Job] {
        guard let selectedId = selectedProfileId else {
            return jobStore.jobs
        }
        return jobStore.jobs.filter { $0.profileId == selectedId }
    }

    private var jobHistoryView: some View {
        VStack(spacing: 0) {
            operationsPanelHeader("RECENT JOBS") {
                Button {
                    clearJobHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Clear job history")
                .accessibilityLabel("Clear Job History")
                .disabled(!canClearJobHistory)
            }

            if selectedProfileJobs.isEmpty {
                operationsEmptyState("No jobs yet")
            } else {
                List {
                    ForEach(Array(selectedProfileJobs.prefix(50))) { job in
                        Button {
                            jobRunner.loadJob(job)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.callout)
                                HStack(spacing: 4) {
                                    statusDot(for: job.step)
                                    Text(stepTitle(job.step))
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
                        .padding(.vertical, 1)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(drawerBackground)
            }
        }
    }

    // MARK: - Image Queue

    private var filesArea: some View {
        let files = filesForDisplay()
        return VStack(spacing: 0) {
            ZStack {
                List(selection: $selectedFileRowIDs) {
                    ForEach(files) { file in
                        fileRow(for: file, job: jobRunner.currentJob)
                            .tag(file.id)
                            .contextMenu {
                                if file.source == .queued {
                                    Button("Delete") {
                                        deleteFileRows(targeting: file)
                                    }
                                    .disabled(jobRunner.isRunning)
                                }
                            }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .background(Self.editorBackground)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .padding(8)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    Task {
                        let urls = await loadFileURLs(from: providers)
                        await MainActor.run {
                            addFiles(urls)
                        }
                    }
                    return true
                }
                .onDeleteCommand {
                    deleteSelectedFileRows()
                }

                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Drop photos here")
                            .font(.headline)
                        Text("JPG, JPEG, JPE, GIF, PNG, BMP, ICO, WebP, AVIF, HEIC, PDF")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Browse…") { choosePhotos() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Self.chromeBackground.opacity(0.9))
                    )
                }
            }
        }
        .onChange(of: droppedFileItems) { _, _ in
            pruneFileSelection()
        }
        .onChange(of: jobRunner.currentJob?.id) { _, _ in
            pruneFileSelection()
        }
    }

    private var canClearFiles: Bool {
        WorkspaceCommandState.canClearFiles(
            isRunning: jobRunner.isRunning,
            queuedCount: droppedFileItems.count,
            hasCurrentJob: jobRunner.currentJob != nil
        )
    }

    private var canStartAction: Bool {
        WorkspaceCommandState.canStartUpload(
            isRunning: jobRunner.isRunning,
            hasSelectedProfile: selectedProfile != nil,
            queuedCount: droppedFileItems.count
        )
    }

    private var canStopAction: Bool {
        WorkspaceCommandState.canStopUpload(isRunning: jobRunner.isRunning)
    }

    private var canResetAction: Bool {
        canClearFiles
    }

    private var canDeleteSelectedFilesAction: Bool {
        let hasQueuedSelection = filesForDisplay().contains {
            selectedFileRowIDs.contains($0.id) && $0.source == .queued
        }
        return WorkspaceCommandState.canDeleteSelectedFiles(
            isRunning: jobRunner.isRunning,
            selectedCount: selectedFileRowIDs.count,
            hasQueuedSelection: hasQueuedSelection
        )
    }

    private var canUseCurrentJobAction: Bool {
        jobRunner.currentJob != nil
    }

    private var canCopyVisibleLogAction: Bool {
        !jobRunner.logLines.isEmpty
    }

    private var windowCommandActions: WindowCommandActions {
        WindowCommandActions(
            createProfile: presentNewProfileEditor,
            editSelectedProfile: {
                guard let selectedProfile else { return }
                presentProfileEditor(for: selectedProfile)
            },
            deleteSelectedProfile: {
                guard let selectedProfile else { return }
                deleteProfile(selectedProfile)
            },
            addFiles: choosePhotos,
            deleteSelectedFiles: deleteSelectedFileRows,
            resetQueueAndCurrentJob: clearAllFiles,
            retryFailedFiles: {
                guard let profile = retryProfile else { return }
                jobRunner.retryFailed(profile: profile)
            },
            stopUpload: {
                jobRunner.cancel()
            },
            startUpload: startQueuedUpload,
            clearJobHistory: clearJobHistory,
            openLog: openLogs,
            copyVisibleLog: copyVisibleLog,
            copyReport: copyReport,
            exportJSONReport: {
                exportReport(as: .json)
            },
            exportCSVReport: {
                exportReport(as: .csv)
            },
            showActiveJobTab: {
                selectOperationsPane(.activeJob)
            },
            showTerminalTab: {
                selectOperationsPane(.terminal)
            },
            showJobHistoryTab: {
                selectOperationsPane(.history)
            },
            canEditSelectedProfile: selectedProfile != nil,
            canDeleteSelectedProfile: canDeleteProfile,
            canDeleteSelectedFiles: canDeleteSelectedFilesAction,
            canResetQueueAndCurrentJob: canResetAction,
            canRetryFailedFiles: jobRunner.canRetryFailed && retryProfile != nil,
            canStopUpload: canStopAction,
            canStartUpload: canStartAction,
            canClearJobHistory: canClearJobHistory,
            canOpenLog: canUseCurrentJobAction,
            canCopyVisibleLog: canCopyVisibleLogAction,
            canCopyReport: canUseCurrentJobAction,
            canExportJSONReport: canUseCurrentJobAction,
            canExportCSVReport: canUseCurrentJobAction
        )
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
        let rowStatus = fileRowStatus(for: file, in: job)

        return HStack(spacing: 8) {
            FileThumbnailIcon(url: item.localURL, size: 20)
            Text(item.filename)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            perItemIndicator(for: file, rowStatus: rowStatus, in: job)
            Text(rowStatus.label.uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(rowStatusColor(rowStatus))
                .frame(width: 108, alignment: .trailing)
        }
        .help(
            FileRowPresentation.helpText(
                for: item,
                isQueuedSource: file.source == .queued
            )
        )
        .contentShape(Rectangle())
    }

    private func perItemIndicator(for file: DisplayFile, rowStatus: FileRowStatus, in job: Job?) -> some View {
        Group {
            switch rowStatus {
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .regenerated:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .uploading, .verifying, .importing, .regenerating:
                if isActivelyRunning(file, in: job) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "clock").foregroundStyle(.secondary)
                }
            case .uploaded, .verified, .imported:
                statusDot(for: file.item.status)
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

    private func fileRowStatus(for file: DisplayFile, in job: Job?) -> FileRowStatus {
        FileRowStatus.resolve(
            item: file.item,
            isQueuedSource: file.source == .queued,
            isActiveFile: isActivelyRunning(file, in: job),
            currentStep: job?.step
        )
    }

    private func activeFileStatus(for job: Job) -> FileRowStatus? {
        guard let activeFileId = job.activeFileId else { return nil }
        guard let activeFile = job.localFiles.first(where: { $0.id == activeFileId }) else { return nil }
        return FileRowStatus.resolve(
            item: activeFile,
            isQueuedSource: false,
            isActiveFile: true,
            currentStep: job.step
        )
    }

    private func rowStatusColor(_ status: FileRowStatus) -> Color {
        switch status.tone {
        case .failure:
            return .red
        case .success:
            return .green
        case .progress:
            return .blue
        case .secondary:
            return .secondary
        }
    }


    private func jobStatusHeader(job: Job) -> some View {
        let presentation = JobPresentation.make(
            for: job,
            activeFileStatus: activeFileStatus(for: job),
            now: Date(),
            anchor: runtimeAnchors[job.id],
            durationFormatter: Self.durationFormatter
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(stepTitle(job.step), systemImage: stepIcon(job.step))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(stepColor(job.step))
                Spacer()
                if jobRunner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(presentation.statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack {
                Text(presentation.progressLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(presentation.etaLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: presentation.overallProgress)

            HStack {
                Text(presentation.rateLine)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    progressMetricLabel("Queued")
                    progressMetricValue(presentation.queuedFiles)
                    progressMetricLabel("Uploaded")
                    progressMetricValue(presentation.uploadedFiles)
                }
                GridRow {
                    progressMetricLabel("Verified")
                    progressMetricValue(presentation.verifiedFiles)
                    progressMetricLabel("Imported")
                    progressMetricValue(presentation.importedFiles)
                }
                GridRow {
                    progressMetricLabel("Succeeded")
                    progressMetricValue(presentation.successfulFiles, color: .green)
                    progressMetricLabel("Failed")
                    progressMetricValue(
                        presentation.failedFiles,
                        color: presentation.failedFiles > 0 ? .red : .secondary
                    )
                }
                GridRow {
                    progressMetricLabel("Remaining")
                    progressMetricValue(presentation.remainingFiles)
                    EmptyView()
                    EmptyView()
                }
            }
        }
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 0) {
            operationsPanelHeader("TERMINAL") {
                Button {
                    openLogs()
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Open log file")
                .accessibilityLabel("View Log")
                .disabled(jobRunner.currentJob == nil)

                Button {
                    copyVisibleLog()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Copy visible terminal lines")
                .accessibilityLabel("Copy Terminal")
                .disabled(!canCopyVisibleLogAction)

                Button {
                    copyReport()
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
                .help("Copy report")
                .accessibilityLabel("Copy Report")
                .disabled(jobRunner.currentJob == nil)

                Menu {
                    Button("Export JSON…") {
                        exportReport(as: .json)
                    }
                    Button("Export CSV…") {
                        exportReport(as: .csv)
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .font(.caption)
                .controlSize(.small)
                .help("Export report")
                .accessibilityLabel("Export")
                .disabled(jobRunner.currentJob == nil)
            }

            terminalContent
        }
    }

    private func operationsPanelHeader(_ title: String) -> some View {
        operationsPanelHeader(title) {
            EmptyView()
        }
    }

    private func operationsPanelHeader<Actions: View>(
        _ title: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Self.sectionHeaderFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(drawerBackground)
    }

    private func paneHeaderButton(
        systemImage: String,
        help: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(help)
    }

    // MARK: - Helpers

    private func setProfilesDrawerVisible(_ isVisible: Bool) {
        let targetVisibility = WorkspaceLayoutState.splitVisibility(forProfilesDrawer: isVisible)
        guard splitViewVisibility != targetVisibility else { return }

        withAnimation(drawerTransitionAnimation) {
            splitViewVisibility = targetVisibility
        }
    }

    private func setOperationsDrawerVisible(_ isVisible: Bool) {
        let targetPane: WorkspaceOperationsTab? = isVisible ? activeOperationsTab : nil
        guard rightPane != targetPane else { return }

        withAnimation(drawerTransitionAnimation) {
            rightPane = targetPane
        }
    }

    private func selectOperationsPane(_ tab: WorkspaceOperationsTab) {
        withAnimation(drawerTransitionAnimation) {
            rightPane = tab
        }
    }


    private var retryProfile: ServerProfile? {
        guard let job = jobRunner.currentJob else { return nil }
        return profileStore.profiles.first(where: { $0.id == job.profileId })
    }

    private var canDeleteProfile: Bool {
        selectedProfile != nil && !jobRunner.isRunning
    }

    private var canClearJobHistory: Bool {
        WorkspaceCommandState.canClearJobHistory(
            isRunning: jobRunner.isRunning,
            jobCount: jobStore.jobs.count
        )
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

    @MainActor
    private func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = {
            let extensions = ["jpg", "jpeg", "jpe", "gif", "png", "bmp", "ico", "webp", "avif", "heic", "pdf"]
            var seen = Set<String>()
            var types: [UTType] = []
            for ext in extensions {
                guard let type = UTType(filenameExtension: ext) else { continue }
                if seen.insert(type.identifier).inserted {
                    types.append(type)
                }
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

        var existing = Set(droppedFileItems.map { $0.localURL.standardizedFileURL.path })
        for url in imageFiles {
            let key = url.standardizedFileURL.path
            guard existing.insert(key).inserted else { continue }
            guard let item = FileItem.fromURL(url) else { continue }
            droppedFileItems.append(item)
        }
        pruneFileSelection()
    }

    private func ingestExternalFiles() {
        addFiles(externalFileIntake.drain())
    }

    private func clearAllFiles() {
        guard !jobRunner.isRunning else { return }
        droppedFileItems.removeAll()
        selectedFileRowIDs.removeAll()
        jobRunner.currentJob = nil
    }

    private func startQueuedUpload() {
        guard let profile = selectedProfile else { return }
        let queued = droppedFileItems.map(\.localURL)
        guard !queued.isEmpty else { return }

        jobRunner.start(profile: profile, fileURLs: queued)
        if jobRunner.isRunning {
            droppedFileItems.removeAll()
            selectedFileRowIDs.removeAll()
            selectOperationsPane(.activeJob)
        }
    }

    private func deleteSelectedFileRows() {
        guard !jobRunner.isRunning else { return }
        guard !selectedFileRowIDs.isEmpty else { return }
        deleteQueuedFiles(forRowIDs: selectedFileRowIDs)
    }

    private func deleteFileRows(targeting file: DisplayFile) {
        guard !jobRunner.isRunning else { return }
        guard file.source == .queued else { return }

        let targetRowIDs: Set<String>
        if selectedFileRowIDs.contains(file.id) {
            targetRowIDs = selectedFileRowIDs
        } else {
            targetRowIDs = [file.id]
        }
        deleteQueuedFiles(forRowIDs: targetRowIDs)
    }

    private func deleteQueuedFiles(forRowIDs rowIDs: Set<String>) {
        guard !rowIDs.isEmpty else { return }

        let queuedItemIDs = Set(
            filesForDisplay()
                .filter { rowIDs.contains($0.id) && $0.source == .queued }
                .map(\.item.id)
        )
        guard !queuedItemIDs.isEmpty else { return }

        droppedFileItems.removeAll { queuedItemIDs.contains($0.id) }
        selectedFileRowIDs.subtract(rowIDs)
        pruneFileSelection()
    }

    private func pruneFileSelection() {
        let validRowIDs = Set(filesForDisplay().map(\.id))
        selectedFileRowIDs.formIntersection(validRowIDs)
    }

    private func copyReport() {
        let text = jobRunner.reportText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func copyVisibleLog() {
        let text = jobRunner.logLines
            .suffix(Self.visibleLogLineLimit)
            .joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private func exportReport(as format: ReportExportFormat) {
        guard let payload = jobRunner.reportPayload(format: format) else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = jobRunner.suggestedReportFileName(format: format)
        panel.allowedContentTypes = [contentType(for: format)]

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            try payload.write(to: destination, atomically: true, encoding: String.Encoding.utf8)
        } catch {
            jobRunner.blockingError = "Failed to export: \(error.localizedDescription)"
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

    private func stepTitle(_ step: JobStep) -> String {
        step.rawValue.capitalized
    }

    private func seedRuntimeAnchorForActiveJob(force: Bool = false) {
        guard let job = jobRunner.currentJob else { return }
        guard !job.step.isTerminal else { return }
        if !force, runtimeAnchors[job.id] != nil { return }
        runtimeAnchors[job.id] = JobRuntimeAnchor(
            startedAt: Date(),
            processedBaseline: JobPresentation.processedFileCount(in: job)
        )
    }

    private func progressMetricLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func progressMetricValue(_ value: Int, color: Color = .primary) -> some View {
        Text("\(value)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(color)
            .frame(minWidth: 24, alignment: .trailing)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter
    }()
}
