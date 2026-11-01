import SwiftUI

struct GameDetailView: View {
    @Environment(AppModel.self) private var model
    let gameId: UUID

    @State private var showEditor = false
    @State private var showDeleteConfirm = false

    private var game: Game? { model.games.first(where: { $0.id == gameId }) }
    private var analysis: SyncAnalysis? { model.analyses[gameId] }

    var body: some View {
        Group {
            if let game {
                content(game)
            } else {
                ContentUnavailableView(model.l.t("Delete Game"), systemImage: "trash")
            }
        }
        .navigationTitle(game?.name ?? "GameSaveSync")
        .sheet(isPresented: $showEditor) {
            if let game { GameEditorView(gameID: game.id) }
        }
        .confirmationDialog(model.l.t("Delete this game configuration?"),
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button(model.l.t("Delete Configuration"), role: .destructive) {
                if let game {
                    model.deleteGame(game)
                    showDeleteConfirm = false
                }
            }
            Button(model.l.t("Cancel"), role: .cancel) {}
        } message: {
            Text(model.l.t("The save files themselves are not deleted. Only the configuration is removed from this device."))
        }
        .task {
            if let game {
                await model.refresh(game)
                model.loadHistory(for: game)
                model.loadLocalBackups(for: game)
                model.loadLeftovers(for: game)
            }
        }
    }

    @ViewBuilder
    private func content(_ game: Game) -> some View {
        Form {
            statusSection(game)
            actionsSection(game)
            if let analysis, let remote = analysis.remote {
                cloudSection(game, analysis: analysis, remote: remote)
            }
            recoverySection(game)
            historySection(game)
            localBackupSection(game)
            dangerSection(game)
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }

    // MARK: - Sections

    private func statusSection(_ game: Game) -> some View {
        Section {
            if let analysis {
                let presentation = analysis.presentation(game: game, localizer: model.l)
                HStack {
                    StatusPill(presentation: presentation)
                    Spacer()
                }
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            InfoRow(label: model.l.t("Local"), value: DateText.stamp(analysis?.local?.newestModified, language: model.l.language))
            InfoRow(label: model.l.t("Cloud"), value: DateText.stamp(analysis?.remote?.saveModifiedAt, language: model.l.language))

            if let local = analysis?.local, local.fileCount > 0 {
                InfoRow(label: model.l.t("Files"),
                        value: "\(model.l.files(local.fileCount)) · \(ByteText.string(local.totalBytes))")
            }

            if let lastSync = game.lastSync {
                let text = "\(DateText.stamp(lastSync.date, language: model.l.language)) · \(kindText(lastSync.kind))"
                InfoRow(label: model.l.t("Last Sync"), value: text)
            }

            InfoRow(label: model.l.t("Game ID"), value: game.gameId, mono: true)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.l.t("Sync Folder"))
                    .foregroundStyle(.secondary)
                Text(game.syncPathDescription)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.primary)
                if game.accessRootIsLegacy {
                    Text(model.l.t("This game uses an older folder grant. Choose the game's Documents folder to sync a subfolder."))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(model.l.t("Status"))
        }
    }

    private func actionsSection(_ game: Game) -> some View {
        Section {
            PrimaryActionButton(title: model.l.t("Sync"),
                                symbol: "arrow.triangle.2.circlepath",
                                prominent: true) {
                model.sync(game)
            }
            .disabled(model.isBusyAtAll)

            HStack(spacing: 10) {
                PrimaryActionButton(title: model.l.t("Upload"),
                                    symbol: "arrow.up.circle",
                                    prominent: false) {
                    model.requestUpload(game)
                }
                .disabled(model.isBusyAtAll)

                PrimaryActionButton(title: model.l.t("Restore"),
                                    symbol: "arrow.down.circle",
                                    prominent: false) {
                    model.requestRestore(game)
                }
                .disabled(model.isBusyAtAll || analysis?.remote == nil)
            }

            if let operation = model.busy, operation.gameId == game.id {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(model.l.t(operation.phase?.text ?? "Checking…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.l.t("Close the game before syncing. GameSaveSync backs up your current saves, then replaces the folder you selected."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text(model.l.t("Actions"))
        }
    }

    private func cloudSection(_ game: Game, analysis: SyncAnalysis, remote: CloudManifest) -> some View {
        Section {
            InfoRow(label: model.l.t("Backup"), value: DateText.dayTime(remote.backupCreatedAt, language: model.l.language))
            InfoRow(label: model.l.t("Files"), value: "\(model.l.files(remote.fileCount)) · \(ByteText.string(remote.totalBytes))")
            InfoRow(label: model.l.t("Source"), value: remote.sourceDevice)
            InfoRow(label: model.l.t("Version"), value: remote.versionId, mono: true)
            if remote.saveModifiedAt == nil || remote.saveWasEmpty {
                Text(model.l.t("Local save folder is empty"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(model.l.t("Cloud"))
        }
    }

    @ViewBuilder
    private func recoverySection(_ game: Game) -> some View {
        let items = model.leftovers[game.id] ?? []
        if !items.isEmpty {
            Section {
                ForEach(items) { leftover in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.l.t("Interrupted operation found"))
                            .font(.subheadline.weight(.semibold))
                        Text(model.l.t("A previous replacement did not finish. The old saves were kept here."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            if leftover.kind == .previous {
                                Button(model.l.t("Recover Old Saves")) {
                                    Task { await model.recoverLeftover(leftover, for: game) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            Button(model.l.t("Discard"), role: .destructive) {
                                model.discardLeftover(leftover, for: game)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                            Text(model.l.files(leftover.fileCount))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text(model.l.t("Warning"))
            }
        }
    }

    @ViewBuilder
    private func historySection(_ game: Game) -> some View {
        let entries = model.cloudHistory[game.id] ?? []
        Section {
            if entries.isEmpty {
                Text(model.l.t("No history yet"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(DateText.dayTime(entry.backupCreatedAt, language: model.l.language))
                                .font(.subheadline)
                            Text("\(DateText.stamp(entry.saveModifiedAt, language: model.l.language)) · \(model.l.files(entry.fileCount)) · \(entry.sourceDevice)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.l.t("Restore")) {
                            model.requestRestoreHistory(game, entry: entry)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusyAtAll)
                    }
                }
            }
        } header: {
            Text(model.l.t("Cloud History"))
        }
    }

    @ViewBuilder
    private func localBackupSection(_ game: Game) -> some View {
        let entries = model.localBackups[game.id] ?? []
        Section {
            if entries.isEmpty {
                Text(model.l.t("No local backups yet"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { backup in
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(DateText.dayTime(backup.createdAt, language: model.l.language))
                                .font(.subheadline)
                            Text("\(model.l.files(backup.fileCount)) · \(ByteText.string(backup.totalBytes))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.l.t("Restore")) {
                            model.requestRestoreLocalBackup(game, backup: backup)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusyAtAll)
                    }
                }
            }
        } header: {
            Text(model.l.t("Local Backups"))
        }
    }

    private func dangerSection(_ game: Game) -> some View {
        Section {
            Button(model.l.t("Edit Game")) { showEditor = true }
                .disabled(model.isBusyAtAll)
            Button(model.l.t("Delete Game"), role: .destructive) {
                showDeleteConfirm = true
            }
            .disabled(model.isBusyAtAll)
        }
    }

    private func kindText(_ kind: SyncRecord.Kind) -> String {
        switch kind {
        case .uploaded: return model.l.t("Uploaded")
        case .uploadedPendingICloud: return model.l.t("Uploaded (waiting for iCloud)")
        case .restored: return model.l.t("Restored")
        case .restoredHistory: return model.l.t("Restored from history")
        case .upToDate: return model.l.t("Already up to date")
        case .failed: return model.l.t("Error")
        }
    }
}
