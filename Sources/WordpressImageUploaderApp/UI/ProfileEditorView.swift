import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let jobRunner: JobRunner
    let onSave: (ServerProfile, String, String) -> Void

    @State private var profile: ServerProfile
    @State private var password: String
    @State private var keyPassphrase: String
    @State private var portText: String
    @State private var showKeyImporter = false

    @State private var isTesting = false
    @State private var testLines: [String] = []
    @State private var testSuccess = false

    init(
        profile: ServerProfile,
        initialPassword: String?,
        initialKeyPassphrase: String?,
        jobRunner: JobRunner,
        onSave: @escaping (ServerProfile, String, String) -> Void
    ) {
        self.jobRunner = jobRunner
        self.onSave = onSave
        _profile = State(initialValue: profile)
        _password = State(initialValue: initialPassword ?? "")
        _keyPassphrase = State(initialValue: initialKeyPassphrase ?? "")
        _portText = State(initialValue: String(profile.port))
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                wordpressSection
                defaultsSection
                connectionTestSection
            }
            .formStyle(.grouped)
            .navigationTitle("Profile Editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                }
            }
        }
        .fileImporter(
            isPresented: $showKeyImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                return
            }
            profile.keyPath = url.path
        }
        .frame(width: 720, height: 760)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        Section(header: Text("Connection")) {
            TextField("Profile Name", text: $profile.name, prompt: Text("My WordPress Server"))
            TextField("Host", text: $profile.host, prompt: Text("example.com"))
            TextField("Username", text: $profile.username, prompt: Text("deploy"))

            LabeledContent("Port") {
                TextField("", text: portBinding, prompt: Text("22"))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }

            Picker("Authentication", selection: $profile.authType) {
                ForEach(AuthenticationType.allCases) { auth in
                    Text(auth.displayName).tag(auth)
                }
            }
            .pickerStyle(.menu)

            if profile.authType == .sshKey {
                HStack {
                    TextField("Optional", text: Binding(
                        get: { profile.keyPath ?? "" },
                        set: { profile.keyPath = trimmed($0).isEmpty ? nil : $0 }
                    ))
                    .font(.body.monospaced())

                    Button("Choose…") {
                        showKeyImporter = true
                    }
                }
                SecureField("Key Passphrase (optional)", text: $keyPassphrase)
            } else {
                SecureField("Password", text: $password)
            }
        }
    }

    // MARK: - WordPress

    private var wordpressSection: some View {
        Section(header: Text("WordPress")) {
            TextField("WP Root Path", text: $profile.wpRootPath, prompt: Text("/var/www/html"))
                .font(.body.monospaced())
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        Section(header: Text("Defaults")) {
            TextField("Staging Root", text: $profile.remoteStagingRoot, prompt: Text("~/wp-media-import"))
                .font(.body.monospaced())

            Toggle("Keep remote files after success", isOn: $profile.keepRemoteFiles)
            Toggle("Play notification sound on completion", isOn: $profile.playCompletionSoundOnCompletion)
        }
    }

    private var connectionTestSection: some View {
        Section(header: Text("Validation")) {
            HStack {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    runConnectionTest()
                }
                .disabled(isTesting || !canSave)

                if !testLines.isEmpty {
                    Label(testSuccess ? "Passed" : "Failed", systemImage: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(testSuccess ? .green : .red)
                }
                Spacer()
            }

            if !testLines.isEmpty {
                ForEach(Array(testLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var canSave: Bool {
        connectionStepValid && wordpressStepValid && defaultsStepValid
    }

    private var connectionStepValid: Bool {
        let base = !trimmed(profile.name).isEmpty
            && !trimmed(profile.host).isEmpty
            && !trimmed(profile.username).isEmpty
            && profile.port > 0

        guard base else { return false }

        switch profile.authType {
        case .sshKey:
            return isKeyPathValid
        case .password:
            return !trimmed(password).isEmpty
        }
    }

    private var wordpressStepValid: Bool {
        !trimmed(profile.wpRootPath).isEmpty
    }

    private var defaultsStepValid: Bool {
        !trimmed(profile.remoteStagingRoot).isEmpty
    }

    private var isKeyPathValid: Bool {
        guard let keyPath = profile.keyPath, !trimmed(keyPath).isEmpty else {
            return true
        }
        return FileManager.default.fileExists(atPath: keyPath)
    }

    private func saveAndClose() {
        profile.port = Int(portText) ?? 0
        profile.bwLimitKBps = nil

        onSave(
            profile,
            password,
            keyPassphrase
        )
        dismiss()
    }

    private var portBinding: Binding<String> {
        Binding(
            get: { portText },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                portText = digits
                profile.port = Int(digits) ?? 0
            }
        )
    }

    private func runConnectionTest() {
        isTesting = true
        testLines = []
        testSuccess = false

        Task {
            let result = await jobRunner.testConnection(
                profile: profile,
                password: password.isEmpty ? nil : password,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
            await MainActor.run {
                testLines = result.checks
                testSuccess = result.success
                isTesting = false
            }
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
