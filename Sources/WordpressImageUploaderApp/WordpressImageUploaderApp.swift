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
    @State private var jobRunner: JobRunner
    @State private var externalFileIntake: ExternalFileIntake
    @State private var showProfilesDrawer = true
    @State private var showOperationsDrawer = true
    @State private var showAbout = false
    @AppStorage("appearanceMode") private var appearanceModeRaw = AppearanceMode.auto.rawValue
    @NSApplicationDelegateAdaptor(DockFileOpenDelegate.self) private var dockFileOpenDelegate

    init() {
        let profiles = ProfileStore()
        let jobs = JobStore()
        let fileIntake = ExternalFileIntake.shared

        _profileStore = State(initialValue: profiles)
        _jobStore = State(initialValue: jobs)
        _jobRunner = State(initialValue: JobRunner(profileStore: profiles, jobStore: jobs))
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

    private func applyAppearance() {
        NSApp.appearance = appearanceMode.nsAppearance
    }

    private func applyWindowChrome() {
        for window in NSApp.windows {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }

    private var minimumWindowWidth: CGFloat {
        let workbenchMinWidth: CGFloat = 420
        let profilesDrawerMinWidth: CGFloat = showProfilesDrawer ? 260 : 0
        let operationsDrawerMinWidth: CGFloat = showOperationsDrawer ? 320 : 0
        return workbenchMinWidth + profilesDrawerMinWidth + operationsDrawerMinWidth
    }

    var body: some Scene {
        WindowGroup("") {
            ContentView(
                profileStore: profileStore,
                jobStore: jobStore,
                jobRunner: jobRunner,
                externalFileIntake: externalFileIntake,
                showProfilesDrawer: $showProfilesDrawer,
                showOperationsDrawer: $showOperationsDrawer
            )
            .frame(minWidth: minimumWindowWidth, minHeight: 600)
            .preferredColorScheme(appearanceMode.preferredColorScheme)
            .onAppear {
                applyAppearance()
                DispatchQueue.main.async {
                    applyWindowChrome()
                }
            }
            .onChange(of: appearanceModeRaw) { _, _ in
                applyAppearance()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(appDisplayName)") {
                    showAbout = true
                }
            }

            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Show Profiles Drawer", isOn: $showProfilesDrawer)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Toggle("Show Operations Drawer", isOn: $showOperationsDrawer)
                    .keyboardShortcut("o", modifiers: [.command, .shift])

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

            Link("GitHub Repository", destination: URL(string: "https://github.com/ddegner/WordpressMediaUploader")!)
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
