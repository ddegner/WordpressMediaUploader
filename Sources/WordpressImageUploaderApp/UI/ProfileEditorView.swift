import SwiftUI

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let jobRunner: JobRunner
    let onSave: (ServerProfile, String?, String?) -> Void

    @State private var profile: ServerProfile
    @State private var password: String
    @State private var keyPassphrase: String
    @State private var portText: String
    @State private var bandwidthLimitText: String
    @State private var showKeyImporter = false

    @State private var isTesting = false
    @State private var testLines: [String] = []
    @State private var testSuccess = false

    init(
        profile: ServerProfile,
        initialPassword: String?,
        initialKeyPassphrase: String?,
        jobRunner: JobRunner,
        onSave: @escaping (ServerProfile, String?, String?) -> Void
    ) {
        self.jobRunner = jobRunner
        self.onSave = onSave
        _profile = State(initialValue: profile)
        _password = State(initialValue: initialPassword ?? "")
        _keyPassphrase = State(initialValue: initialKeyPassphrase ?? "")
        _portText = State(initialValue: String(profile.port))
        _bandwidthLimitText = State(initialValue: profile.bwLimitKBps.map(String.init) ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Profile Setup")
                .font(.title3.weight(.semibold))

            GroupBox {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        connectionSection
                        Divider()
                        wordpressSection
                        Divider()
                        defaultsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        runConnectionTest()
                    }
                    .disabled(isTesting || !canSave)

                    if !testLines.isEmpty {
                        Image(systemName: testSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testSuccess ? .green : .red)
                        Text(testSuccess ? "Passed" : "Failed")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(testSuccess ? .green : .red)
                    }
                }

                if !testLines.isEmpty {
                    ForEach(Array(testLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Save") {
                    saveAndClose()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
        .padding(18)
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
        .frame(width: 640, height: 620)
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server")
                .font(.headline)

            labeledTextField("Profile Name", text: $profile.name, placeholder: "My WordPress Server")
            labeledTextField("Host", text: $profile.host, placeholder: "example.com")
            labeledTextField("Username", text: $profile.username, placeholder: "deploy")

            HStack(spacing: 10) {
                Text("Port")
                    .frame(width: 150, alignment: .leading)
                TextField("22", text: portBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                Spacer()
            }

            Divider()

            Text("Authentication")
                .font(.headline)

            Picker("Method", selection: $profile.authType) {
                ForEach(AuthenticationType.allCases) { auth in
                    Text(auth.displayName).tag(auth)
                }
            }

            if profile.authType == .sshKey {
                HStack(spacing: 10) {
                    Text("Private Key")
                        .frame(width: 150, alignment: .leading)
                    TextField("Optional", text: Binding(
                        get: { profile.keyPath ?? "" },
                        set: { profile.keyPath = trimmed($0).isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Button("Choose…") {
                        showKeyImporter = true
                    }
                }

                HStack(spacing: 10) {
                    Text("Key Passphrase")
                        .frame(width: 150, alignment: .leading)
                    SecureField("Optional", text: $keyPassphrase)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Recommended: use ssh-agent for key auth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Text("Password")
                        .frame(width: 150, alignment: .leading)
                    SecureField("Required", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Password is stored in Keychain and used via SSH_ASKPASS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - WordPress

    private var wordpressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WordPress")
                .font(.headline)

            labeledTextField("WP Root Path", text: $profile.wpRootPath, placeholder: "/var/www/html")

            Text("This is the directory containing wp-config.php on the remote server.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Defaults

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Defaults")
                .font(.headline)

            labeledTextField("Staging Root", text: $profile.remoteStagingRoot, placeholder: "~/wp-media-import")

            HStack(spacing: 10) {
                Text("Bandwidth Limit")
                    .frame(width: 150, alignment: .leading)
                TextField("Unlimited", text: bandwidthLimitBinding)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                Text("KB/s")
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Toggle("Keep remote files after success", isOn: $profile.keepRemoteFiles)

            Text("Defaults: port 22, staging ~/wp-media-import.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func labeledTextField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 150, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
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
        if let limit = Int(bandwidthLimitText), limit > 0 {
            profile.bwLimitKBps = limit
        } else {
            profile.bwLimitKBps = nil
        }

        onSave(
            profile,
            password.isEmpty ? nil : password,
            keyPassphrase.isEmpty ? nil : keyPassphrase
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

    private var bandwidthLimitBinding: Binding<String> {
        Binding(
            get: { bandwidthLimitText },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                bandwidthLimitText = digits
                if let limit = Int(digits), limit > 0 {
                    profile.bwLimitKBps = limit
                } else {
                    profile.bwLimitKBps = nil
                }
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
