import AppKit
import SwiftUI

@main
struct WordpressMediaUploaderApp: App {
    private enum AppearanceMode: String, CaseIterable, Identifiable {
        case auto
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .auto: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }

        var nsAppearance: NSAppearance? {
            switch self {
            case .auto: return nil
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            }
        }
    }

    @State private var profileStore: ProfileStore
    @State private var jobStore: JobStore
    @State private var externalFileIntake: ExternalFileIntake
    @State private var showAbout = false
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.auto.rawValue
    @AppStorage(JobRunner.playCompletionSoundDefaultsKey) private var playCompletionSoundOnCompletion = false
    @FocusedBinding(\.showProfilesDrawerBinding) private var focusedShowProfilesDrawer: Bool?
    @FocusedBinding(\.showOperationsDrawerBinding) private var focusedShowOperationsDrawer: Bool?
    @NSApplicationDelegateAdaptor(DockFileOpenDelegate.self) private var dockFileOpenDelegate

    init() {
        let profiles = ProfileStore()
        let jobs = JobStore()
        let fileIntake = ExternalFileIntake.shared

        _profileStore = State(initialValue: profiles)
        _jobStore = State(initialValue: jobs)
        _externalFileIntake = State(initialValue: fileIntake)
    }

    private var appearanceMode: AppearanceMode {
        get { AppearanceMode(rawValue: appearanceModeRaw) ?? .auto }
        set { appearanceModeRaw = newValue.rawValue }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Wordpress Media Uploader"
    }

    private var focusedShowProfilesDrawerToggleBinding: Binding<Bool> {
        Binding(
            get: { focusedShowProfilesDrawer ?? true },
            set: { focusedShowProfilesDrawer = $0 }
        )
    }

    private var focusedShowOperationsDrawerToggleBinding: Binding<Bool> {
        Binding(
            get: { focusedShowOperationsDrawer ?? true },
            set: { focusedShowOperationsDrawer = $0 }
        )
    }

    private func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    var body: some Scene {
        WindowGroup("") {
            AppWindowRootView(
                profileStore: profileStore,
                jobStore: jobStore,
                externalFileIntake: externalFileIntake
            )
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            .onAppear {
                applyAppearance()
            }
            .onChange(of: appearanceModeRaw) { _, _ in
                applyAppearance()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                jobStore.removeActiveJobs()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(appDisplayName)") {
                    showAbout = true
                }
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Show Profiles Drawer", isOn: focusedShowProfilesDrawerToggleBinding)
                    .disabled(focusedShowProfilesDrawer == nil)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Toggle("Show Operations Drawer", isOn: focusedShowOperationsDrawerToggleBinding)
                    .disabled(focusedShowOperationsDrawer == nil)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Toggle("Play Sound on Completion", isOn: $playCompletionSoundOnCompletion)

                Divider()
                Picker("Appearance", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
            }
        }
    }
}

private struct AppWindowRootView: View {
    @Bindable var profileStore: ProfileStore
    @Bindable var jobStore: JobStore
    @Bindable var externalFileIntake: ExternalFileIntake
    @State private var jobRunner: JobRunner

    init(profileStore: ProfileStore, jobStore: JobStore, externalFileIntake: ExternalFileIntake) {
        self.profileStore = profileStore
        self.jobStore = jobStore
        self.externalFileIntake = externalFileIntake
        _jobRunner = State(initialValue: JobRunner(profileStore: profileStore, jobStore: jobStore))
    }

    var body: some View {
        ContentView(
            profileStore: profileStore,
            jobStore: jobStore,
            jobRunner: jobRunner,
            externalFileIntake: externalFileIntake
        )
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Wordpress Media Uploader"
    }

    private var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "—"
    }

    private var buildString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "—"
    }

    private static let repoURL = URL(string: "https://github.com/ddegner/WordpressMediaUploader")!

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text(appDisplayName)
                    .font(.title2.weight(.semibold))

                Text("Version \(versionString) (\(buildString))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Link("GitHub Repository", destination: Self.repoURL)
                .font(.callout)

            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
