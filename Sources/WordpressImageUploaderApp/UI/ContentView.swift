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

    private enum FileProgressState {
        case queued
        case uploading
        case processing
        case processed
        case failed
    }

    private enum OperationsTab: String, CaseIterable, Identifiable {
        case activeJob
        case terminal
        case history

        var id: String { rawValue }

        var title: String {
            switch self {
            case .activeJob: return "Active Job"
            case .terminal: return "Terminal"
            case .history: return "Job History"
            }
        }

        var systemImage: String {
            switch self {
            case .activeJob: return "play.fill"
            case .terminal: return "chevron.left.forwardslash.chevron.right"
            case .history: return "clock"
            }
        }
    }

    private struct OperationsTabsControl: NSViewRepresentable {
        @Binding var selection: OperationsTab
        let tabs: [OperationsTab]

        final class Coordinator: NSObject {
            var parent: OperationsTabsControl

            init(parent: OperationsTabsControl) {
                self.parent = parent
            }

            @MainActor
            @objc func selectionChanged(_ sender: NSSegmentedControl) {
                guard sender.selectedSegment >= 0, sender.selectedSegment < parent.tabs.count else { return }
                parent.selection = parent.tabs[sender.selectedSegment]
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSSegmentedControl {
            let control = NSSegmentedControl()
            control.segmentStyle = .separated
            control.trackingMode = .selectOne
            control.controlSize = .large
            control.segmentDistribution = .fillEqually
            control.target = context.coordinator
            control.action = #selector(Coordinator.selectionChanged(_:))
            configure(control)
            return control
        }

        func updateNSView(_ control: NSSegmentedControl, context: Context) {
            context.coordinator.parent = self
            configure(control)
            control.selectedSegment = tabs.firstIndex(of: selection) ?? -1
        }

        private func configure(_ control: NSSegmentedControl) {
            if control.segmentCount != tabs.count {
                control.segmentCount = tabs.count
            }

            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            for (index, tab) in tabs.enumerated() {
                control.setLabel("", forSegment: index)
                control.setToolTip(tab.title, forSegment: index)
                let image = NSImage(
                    systemSymbolName: tab.systemImage,
                    accessibilityDescription: tab.title
                )?.withSymbolConfiguration(symbolConfig)
                control.setImage(image, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
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
    @State private var showErrorAlert = false
    @State private var showProfilesDrawer = true
    @State private var showOperationsDrawer = false
    @State private var selectedProfileId: UUID?
    @State private var operationsTab: OperationsTab = .activeJob
    @State private var splitViewVisibility: NavigationSplitViewVisibility = .all

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

    private var profilesDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { showProfilesDrawer },
            set: { setProfilesDrawerVisible($0) }
        )
    }

    private var operationsDrawerSceneBinding: Binding<Bool> {
        Binding(
            get: { showOperationsDrawer },
            set: { setOperationsDrawerVisible($0) }
        )
    }

    private var operationsDrawerPresentationBinding: Binding<Bool> {
        Binding(
            get: { showOperationsDrawer },
            set: { setOperationsDrawerVisible($0) }
        )
    }

    private var visibleDrawerWidth: CGFloat {
        (showProfilesDrawer ? Self.profilesDrawerWidth : 0)
        + (showOperationsDrawer ? Self.operationsDrawerWidth : 0)
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
        .inspector(isPresented: operationsDrawerPresentationBinding) {
            operationsDrawer
                .background(drawerBackground)
        }
        .inspectorColumnWidth(
            min: Self.operationsDrawerWidth,
            ideal: Self.operationsDrawerWidth,
            max: Self.operationsDrawerWidth
        )
        .frame(minWidth: minimumWindowWidth, minHeight: 600)
        .background(Self.editorBackground)
        .focusedSceneValue(\.showProfilesDrawerBinding, profilesDrawerSceneBinding)
        .focusedSceneValue(\.showOperationsDrawerBinding, operationsDrawerSceneBinding)
        .focusedSceneValue(\.windowCommandActions, windowCommandActions)
        .onAppear {
            splitViewVisibility = showProfilesDrawer ? .all : .detailOnly
            showOperationsDrawer = true
            ingestExternalFiles()
            if selectedProfileId == nil {
                selectedProfileId = profileStore.profiles.first?.id
            }
            if profileStore.isEmpty {
                presentNewProfileEditor()
            }
        }
        .onChange(of: splitViewVisibility) { _, visibility in
            setProfilesDrawerVisible(isSidebarVisible(for: visibility), syncSplitVisibility: false)
        }
        .onChange(of: externalFileIntake.sequence) { _, _ in
            ingestExternalFiles()
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
                    profileStore.add(updated)
                    selectedProfileId = updated.id
                }
                do {
                    var storedProfile = updated
                    if updated.authType == .password {
                        storedProfile = try profileStore.clearKeyPassphrase(for: storedProfile)
                        if password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            storedProfile = try profileStore.clearPassword(for: storedProfile)
                        } else {
                            storedProfile = try profileStore.savePassword(password, for: storedProfile)
                        }
                    } else {
                        storedProfile = try profileStore.clearPassword(for: storedProfile)
                        if keyPassphrase.isEmpty {
                            storedProfile = try profileStore.clearKeyPassphrase(for: storedProfile)
                        } else {
                            storedProfile = try profileStore.saveKeyPassphrase(keyPassphrase, for: storedProfile)
                        }
                    }
                } catch {
                    jobRunner.errorBanner = "Failed to save credentials: \(error.localizedDescription)"
                }
            }
        }
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
                    if !showProfilesDrawer {
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
                    if !showProfilesDrawer {
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
            .help("Retry only previously failed files; successful files are skipped")
            .accessibilityLabel("Retry only previously failed files; successful files are skipped")

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

        // Inspector Toggle (Far Right)
        ToolbarItemGroup(placement: .primaryAction) {
            Spacer()
            
            Button {
                setOperationsDrawerVisible(!showOperationsDrawer)
            } label: {
                Label("Toggle Inspector", systemImage: "sidebar.right")
            }
            .help(showOperationsDrawer ? "Hide operations drawer" : "Show operations drawer")
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
            OperationsTabsControl(
                selection: $operationsTab,
                tabs: Array(OperationsTab.allCases)
            )
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(drawerBackground)

            Group {
                switch operationsTab {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Active Job")
                    .font(Self.sectionHeaderFont)
                    .foregroundStyle(.secondary)
                Spacer()
                if jobRunner.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let job = jobRunner.currentJob {
                jobStatusHeader(job: job)
            } else {
                Text("No job selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(drawerBackground)
    }

    private var selectedProfileJobs: [Job] {
        guard let selectedId = selectedProfileId else {
            return jobStore.jobs
        }
        return jobStore.jobs.filter { $0.profileId == selectedId }
    }

    private var jobHistoryView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("RECENT JOBS")
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(drawerBackground)

            List {
                if selectedProfileJobs.isEmpty {
                    Text("No jobs yet")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                } else {
                    ForEach(Array(selectedProfileJobs.prefix(50))) { job in
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
                        .padding(.vertical, 1)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(drawerBackground)
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
        !jobRunner.isRunning && (!droppedFileItems.isEmpty || jobRunner.currentJob != nil)
    }

    private var canStartAction: Bool {
        !jobRunner.isRunning && selectedProfile != nil && !droppedFileItems.isEmpty
    }

    private var canStopAction: Bool {
        jobRunner.isRunning
    }

    private var canResetAction: Bool {
        canClearFiles
    }

    private var canDeleteSelectedFilesAction: Bool {
        guard !jobRunner.isRunning, !selectedFileRowIDs.isEmpty else { return false }
        return filesForDisplay().contains { selectedFileRowIDs.contains($0.id) && $0.source == .queued }
    }

    private var canUseCurrentJobAction: Bool {
        jobRunner.currentJob != nil
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
            copyReport: copyReport,
            exportJSONReport: {
                exportReport(as: .json)
            },
            exportCSVReport: {
                exportReport(as: .csv)
            },
            showActiveJobTab: {
                setOperationsDrawerVisible(true)
                operationsTab = .activeJob
            },
            showTerminalTab: {
                setOperationsDrawerVisible(true)
                operationsTab = .terminal
            },
            showJobHistoryTab: {
                setOperationsDrawerVisible(true)
                operationsTab = .history
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
        let progressState = progressState(for: file, in: job)

        return HStack(spacing: 8) {
            FileThumbnailIcon(url: item.localURL, size: 20)
            Text(item.filename)
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer()
            Text(Self.byteFormatter.string(fromByteCount: item.sizeBytes))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            perItemIndicator(for: file, state: progressState, in: job)
            Text(progressLabel(for: progressState).uppercased())
                .font(.caption2.monospaced())
                .foregroundStyle(progressColor(for: progressState))
                .frame(width: 74, alignment: .trailing)
        }
        .help(file.source == .queued ? "Queued for next run" : (item.errorMessage ?? ""))
        .contentShape(Rectangle())
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
                    .font(.callout.weight(.semibold))
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: job.uploadProgress)
                    Text("\(Int(job.uploadProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                GridRow {
                    Text("Import")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: job.importProgress)
                    Text("\(Int(job.importProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
    }

    private var logViewer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TERMINAL")
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
            .background(drawerBackground)

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
            .background(Color(nsColor: .textBackgroundColor))
        }
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

    private func isSidebarVisible(for visibility: NavigationSplitViewVisibility) -> Bool {
        switch visibility {
        case .detailOnly:
            return false
        default:
            return true
        }
    }

    private func splitVisibility(forProfilesDrawer isVisible: Bool) -> NavigationSplitViewVisibility {
        isVisible ? .all : .detailOnly
    }

    private func setProfilesDrawerVisible(_ isVisible: Bool, syncSplitVisibility: Bool = true) {
        let shouldToggleDrawer = showProfilesDrawer != isVisible
        let targetSplitVisibility = splitVisibility(forProfilesDrawer: isVisible)
        let shouldSyncSplitVisibility = syncSplitVisibility && splitViewVisibility != targetSplitVisibility
        guard shouldToggleDrawer || shouldSyncSplitVisibility else { return }

        withAnimation(drawerTransitionAnimation) {
            showProfilesDrawer = isVisible
            if shouldSyncSplitVisibility {
                splitViewVisibility = targetSplitVisibility
            }
        }
    }

    private func setOperationsDrawerVisible(_ isVisible: Bool) {
        guard showOperationsDrawer != isVisible else { return }

        withAnimation(drawerTransitionAnimation) {
            showOperationsDrawer = isVisible
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
        !jobRunner.isRunning && !jobStore.jobs.isEmpty
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
        panel.canChooseDirectories = false
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
            setOperationsDrawerVisible(true)
            operationsTab = .activeJob
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
