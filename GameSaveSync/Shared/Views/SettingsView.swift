import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var owner = ""
    @State private var repositoryName = ""
    @State private var branch = GitHubRepository.fallbackBranch
    @State private var tokenDraft = ""
    @State private var tokenMessage: String?
    @State private var commitTask: Task<Void, Never>?
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Form {
                gitHubSection
                tokenSection
                connectionSection
                historySection
                languageSection
                deviceSection
                aboutSection
            }
            #if os(macOS)
            .frame(width: 560)
            .formStyle(.grouped)
            #endif
            .navigationTitle(model.l.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.l.t("Done")) {
                        commitRepository()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
            .onDisappear { commitTask?.cancel() }
        }
        #if os(macOS)
        .frame(width: 560)
        #endif
    }

    // MARK: - GitHub

    private var gitHubSection: some View {
        Section {
            LabeledContent(model.l.t("Repository Owner")) {
                TextField("ohxiaoguang", text: $owner)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: owner) { _, _ in scheduleCommit() }
            }
            LabeledContent(model.l.t("Repository Name")) {
                TextField(model.l.t("private save repository"), text: $repositoryName)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: repositoryName) { _, _ in scheduleCommit() }
            }
            LabeledContent(model.l.t("Branch")) {
                TextField(GitHubRepository.fallbackBranch, text: $branch)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onChange(of: branch) { _, _ in scheduleCommit() }
            }
        } header: {
            Text(model.l.t("GitHub Repository"))
        } footer: {
            Text(model.l.t("Use a private repository you created for game saves. GameSaveSync writes only to games/<game id>/ and never changes repository settings."))
        }
    }

    private var tokenSection: some View {
        Section {
            SecureField(model.hasStoredToken ? model.l.t("Token saved — enter a new one to replace it") : "github_pat_…",
                        text: $tokenDraft)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            HStack(spacing: 12) {
                Button(model.l.t("Save Token")) {
                    tokenMessage = model.saveToken(tokenDraft)
                    if tokenMessage == nil {
                        tokenDraft = ""
                        model.showToast(.init(text: model.l.t("Token saved in the Keychain"), symbol: "key.fill"))
                    }
                }
                .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.hasStoredToken {
                    Button(model.l.t("Remove Token"), role: .destructive) {
                        model.deleteToken()
                        tokenDraft = ""
                        tokenMessage = nil
                    }
                }
                Spacer()
            }

            HStack(spacing: 6) {
                Image(systemName: model.hasStoredToken ? "checkmark.seal.fill" : "key.slash")
                    .foregroundStyle(model.hasStoredToken ? Color.green : .secondary)
                Text(model.hasStoredToken ? model.l.t("Token stored in the Keychain") : model.l.t("No token stored"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let tokenMessage {
                Text(tokenMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(model.l.t("Access Token"))
        } footer: {
            Text(model.l.t("Fine-grained token with Contents: Read and write on this repository. It is stored in the Keychain, never in settings.json or the logs."))
        }
    }

    private var connectionSection: some View {
        Section {
            Button {
                commitRepository()
                Task { await model.testConnection() }
            } label: {
                HStack(spacing: 8) {
                    if model.isTestingConnection {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.isTestingConnection ? model.l.t("Testing…") : model.l.t("Test Connection"))
                }
            }
            .disabled(model.isTestingConnection || !model.isRemoteConfigured || !model.hasStoredToken)

            if let report = model.connection {
                connectionRow(label: model.l.t("Status"),
                              value: model.l.t("Connected"),
                              tint: .green)
                connectionRow(label: model.l.t("Permissions"),
                              value: permissionText(report),
                              tint: report.canWrite ? .green : .orange)
                connectionRow(label: model.l.t("Repository"),
                              value: report.isPrivate ? model.l.t("Private") : model.l.t("Public"),
                              tint: report.isPrivate ? .green : .red)
                connectionRow(label: model.l.t("Branch"),
                              value: report.isEmptyRepository
                                  ? "\(report.defaultBranch) · \(model.l.t("empty (set up on first upload)"))"
                                  : model.l.t("readable"),
                              tint: .secondary)
            } else if let error = model.connectionError {
                connectionRow(label: model.l.t("Status"),
                              value: model.l.t("Not connected"),
                              tint: .red)
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(model.l.t("Connection"))
        } footer: {
            Text(model.l.t("The test checks that the repository exists, belongs to the owner, is private, and that the token may read and write the branch."))
        }
    }

    private func permissionText(_ report: GitHubConnectionReport) -> String {
        if report.canWrite { return model.l.t("Read and write") }
        if report.canRead { return model.l.t("Read only") }
        return model.l.t("No access")
    }

    private func connectionRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    // MARK: - Other sections

    private var historySection: some View {
        Section {
            Stepper(value: Binding(get: { model.settings.localBackupRetention },
                                   set: { value in model.updateSettings { $0.localBackupRetention = max(1, min(value, 20)) } }),
                    in: 1...10) {
                Text("\(model.l.t("Local Backups"))  \(model.settings.localBackupRetention)")
            }
        } footer: {
            Text(model.l.t("How many safety copies of a save folder are kept on this device. GitHub keeps every uploaded version in its own commit."))
        }
    }

    private var languageSection: some View {
        Section {
            Picker(model.l.t("Language"), selection: Binding(get: { model.settings.language },
                                                             set: { value in model.updateSettings { $0.language = value } })) {
                Text(model.l.t("System Default")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("中文").tag(AppLanguage.chinese)
            }
            #if os(iOS)
            .pickerStyle(.navigationLink)
            #endif
        } header: {
            Text(model.l.t("Language"))
        }
    }

    private var deviceSection: some View {
        Section {
            TextField(model.l.t("Device Name"),
                      text: Binding(get: { model.settings.deviceName },
                                    set: { value in model.updateSettings { $0.deviceName = value } }))
        } footer: {
            Text(model.l.t("Recorded in each manifest so you can see which device uploaded a version."))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(model.l.t("Version"), value: AppModel.appVersion)
            Text(model.l.t("GameSaveSync archives each game's save folder and keeps it in your private GitHub repository. Saves are read only on this device and only when you start a sync."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(model.l.t("About GameSaveSync"))
        }
    }

    // MARK: - Editing

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        owner = model.settings.gitHubOwner
        repositoryName = model.settings.gitHubName
        branch = model.settings.gitHubBranch
    }

    /// Small debounce so typing a repository name does not trigger a sync per keystroke.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { commitRepository() }
        }
    }

    private func commitRepository() {
        let current = GitHubRepository(owner: owner, name: repositoryName, branch: branch)
        guard current != model.repository else { return }
        model.updateRepository(owner: owner, name: repositoryName, branch: branch)
    }
}

struct ConflictView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let request: AppModel.ConflictRequest

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.l.t("Both versions have the same timestamp but different content."))
                    .font(.headline)
                Text(model.l.t("Choose which version to keep. The other side will be overwritten."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    sideRow(title: model.l.t("Local version"),
                            date: DateText.stamp(request.analysis.local?.newestModified, language: model.l.language),
                            files: request.analysis.local?.fileCount ?? 0,
                            bytes: request.analysis.local?.totalBytes ?? 0)
                    Divider()
                    sideRow(title: model.l.t("Remote version"),
                            date: DateText.stamp(request.analysis.remote?.saveModifiedAt, language: model.l.language),
                            files: request.analysis.remote?.fileCount ?? 0,
                            bytes: request.analysis.remote?.totalBytes ?? 0)
                }
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text(model.l.t("An automatic backup of the version being replaced is created first."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    Button {
                        model.resolveConflict(useLocal: true, request: request)
                    } label: {
                        Label(model.l.t("Use Local Version"), systemImage: "arrow.up.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        model.resolveConflict(useLocal: false, request: request)
                    } label: {
                        Label(model.l.t("Use Remote Version"), systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button(model.l.t("Cancel"), role: .cancel) {
                        dismiss()
                    }
                    .controlSize(.large)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .navigationTitle(model.l.t("Needs attention"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(width: 460, height: 520)
        #endif
    }

    private func sideRow(title: String, date: String, files: Int, bytes: Int64) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.medium))
                Text("\(date) · \(model.l.files(files)) · \(ByteText.string(bytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}
