import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                cloudSection
                historySection
                languageSection
                deviceSection
                aboutSection
            }
            #if os(macOS)
            .frame(width: 540)
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(model.l.t("Settings"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.l.t("Done")) { dismiss() }
                }
            }
            .cloudRootWarningAlert()
        }
        #if os(macOS)
        .frame(width: 540)
        #endif
    }

    private var cloudSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.cloudRootConfigured ? "icloud.fill" : "icloud.slash")
                        .foregroundStyle(model.cloudRootConfigured ? Color.accentColor : .secondary)
                    Text(model.cloudRootDescription())
                        .font(.subheadline)
                        .textSelection(.enabled)
                }
                if model.cloudRootConfigured {
                    Text(model.settings.cloudRootIsICloud
                         ? "iCloud Drive"
                         : model.l.t("On this device only — not synced"))
                        .font(.caption)
                        .foregroundStyle(model.settings.cloudRootIsICloud ? Color.secondary : Color.orange)
                }
            }

            FolderPickerButton(title: model.cloudRootConfigured ? model.l.t("Change Folder") : model.l.t("Choose Folder…")) { url in
                model.setCloudRoot(url)
            }
        } header: {
            Text(model.l.t("iCloud Drive Folder"))
        } footer: {
            Text(model.l.t("The folder where all game backups are stored."))
        }
    }

    private var historySection: some View {
        Section {
            Stepper(value: Binding(get: { model.settings.historyRetention },
                                   set: { value in model.updateSettings { $0.historyRetention = max(1, min(value, 20)) } }),
                    in: 1...10) {
                Text("\(model.l.t("History Versions"))  \(model.settings.historyRetention)")
            }
        } footer: {
            Text(model.l.f("Keep last %d versions", model.settings.historyRetention))
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
            Text(model.l.t("Used in backup manifests to show where a backup came from."))
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent(model.l.t("Version"), value: AppModel.appVersion)
            Text(model.l.t("GameSaveSync keeps a complete copy of each game's save folder in iCloud Drive. Everything runs on device: no account, no server, no background sync."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(model.l.t("About GameSaveSync"))
        }
    }
}

struct CloudSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var isInitialSetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                                                       startPoint: .topLeading,
                                                       endPoint: .bottomTrailing),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.l.t("iCloud Drive Folder"))
                                .font(.title3.weight(.semibold))
                            Text(model.cloudRootConfigured ? model.l.t("Configured") : model.l.t("Not configured"))
                                .font(.caption)
                                .foregroundStyle(model.cloudRootConfigured ? Color.green : .secondary)
                        }
                    }

                    if model.cloudRootConfigured {
                        Text(model.l.t("Backups are written into this folder. Choose a different one at any time."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(model.l.t("iCloud Drive is not set up yet. Choose a folder inside iCloud Drive, for example iCloud Drive/GameSaveSync."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        bullet("1", model.l.t("Open the Files app and go to iCloud Drive."))
                        bullet("2", model.l.t("Create a folder named GameSaveSync (or pick any folder you like)."))
                        bullet("3", model.l.t("Come back here and select that folder."))
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if model.cloudRootConfigured {
                        Text(model.cloudRootDescription())
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    FolderPickerButton(title: model.cloudRootConfigured ? model.l.t("Change Folder") : model.l.t("Choose Folder…")) { url in
                        model.setCloudRoot(url)
                        if isInitialSetup, model.cloudRootConfigured {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text(model.l.t("Everything runs on this device. Saves are copied to the iCloud Drive folder you picked."))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(model.l.t("iCloud Drive Folder"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.l.t("Cancel")) { dismiss() }
                }
            }
            .cloudRootWarningAlert {
                if isInitialSetup, model.cloudRootConfigured { dismiss() }
            }
        }
        #if os(macOS)
        .frame(width: 520, height: 520)
        #endif
    }

    private func bullet(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    sideRow(title: model.l.t("Cloud version"),
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
                        Label(model.l.t("Use Cloud Version"), systemImage: "arrow.down.circle.fill")
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

/// Warns when the chosen sync folder is not inside iCloud Drive. Such a folder still works,
/// but nothing leaves the device, so the choice must be explicit.
private struct CloudRootWarningAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    var onAccepted: (() -> Void)?

    func body(content: Content) -> some View {
        content.alert(model.l.t("This folder is not in iCloud Drive"),
                      isPresented: Binding(get: { model.pendingCloudRoot != nil },
                                           set: { if !$0 { model.cancelPendingCloudRoot() } })) {
            Button(model.l.t("Use Anyway"), role: .destructive) {
                model.usePendingCloudRootAnyway()
                onAccepted?()
            }
            Button(model.l.t("Choose Again"), role: .cancel) {
                model.cancelPendingCloudRoot()
            }
        } message: {
            Text(model.l.t("Backups stay on this device and will not appear on your other devices. Choose a folder inside iCloud Drive to sync between iPhone, iPad and Mac."))
        }
    }
}

extension View {
    func cloudRootWarningAlert(onAccepted: (() -> Void)? = nil) -> some View {
        modifier(CloudRootWarningAlert(onAccepted: onAccepted))
    }
}
