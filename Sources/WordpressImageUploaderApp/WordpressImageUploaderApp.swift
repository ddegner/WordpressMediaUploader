import SwiftUI

@main
struct WordpressImageUploaderApp: App {
    @State private var profileStore: ProfileStore
    @State private var jobStore: JobStore
    @State private var jobRunner: JobRunner
    @State private var externalFileIntake: ExternalFileIntake
    @State private var showLogPane = true
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

    var body: some Scene {
        WindowGroup("") {
            ContentView(
                profileStore: profileStore,
                jobStore: jobStore,
                jobRunner: jobRunner,
                externalFileIntake: externalFileIntake,
                showLogPane: $showLogPane
            )
            .frame(minWidth: 900, minHeight: 600)
            .preferredColorScheme(nil)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Toggle("Show Logs", isOn: $showLogPane)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
