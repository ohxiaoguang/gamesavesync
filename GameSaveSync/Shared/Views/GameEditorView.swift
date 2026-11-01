import SwiftUI

struct GameEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let gameID: UUID?

    @State private var name = ""
    @State private var gameId = ""
    @State private var accessRootURL: URL?
    @State private var accessRootHint = ""
    @State private var syncRelativePath = ""
    @State private var showsBrowser = false
    @State private var idWasEdited = false
    @State private var errorMessage: String?
    @State private var didLoad = false

    private var isEditing: Bool { gameID != nil }
    private var existing: Game? { gameID.flatMap { id in model.games.first(where: { $0.id == id }) } }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && Slugger.isValidGameId(Slugger.sanitizeGameId(gameId))
            && (isEditing || accessRootURL != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                idSection
                accessSection
                syncSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if !isEditing {
                    Section {
                        Text(model.l.t("If the cloud already has a backup for this ID, it will be linked automatically."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle(isEditing ? model.l.t("Edit Game") : model.l.t("Add Game"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.l.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.l.t("Save")) { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showsBrowser) {
                if let accessRootURL {
                    SyncFolderBrowserView(root: accessRootURL, initialPath: syncRelativePath) { picked in
                        syncRelativePath = picked
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 640)
        #endif
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(model.l.t("Game Name (e.g. Darkest Dungeon)"), text: $name)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                #if os(macOS)
                .labelsHidden()
                #endif
                .onChange(of: name) { _, newValue in
                    guard !idWasEdited else { return }
                    gameId = Slugger.slug(from: newValue)
                }
        } header: {
            Text(model.l.t("Game Name"))
        }
    }

    private var idSection: some View {
        Section {
            TextField(model.l.t("Game ID"), text: $gameId)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                #if os(macOS)
                .labelsHidden()
                #endif
                .onChange(of: gameId) { _, _ in
                    idWasEdited = true
                    gameId = Slugger.sanitizeGameId(gameId)
                }
        } header: {
            Text(model.l.t("Game ID"))
        } footer: {
            Text(model.l.t("Used to match backups between devices. Letters, numbers, dots and dashes."))
        }
    }

    private var accessSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.l.t("Authorised Folder"))
                        .font(.subheadline)
                    Text(accessRootHint.isEmpty ? model.l.t("Not selected") : accessRootHint)
                        .font(.caption)
                        .foregroundStyle(accessRootHint.isEmpty ? .secondary : .primary)
                        .lineLimit(3)
                }
                Spacer()
                FolderPickerButton(title: accessRootHint.isEmpty ? model.l.t("Choose…") : model.l.t("Change")) { url in
                    accessRootURL = url
                    accessRootHint = PathHint.describe(url)
                    // A new grant invalidates the old sync folder selection.
                    syncRelativePath = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } header: {
            Text(model.l.t("Authorised Folder"))
        } footer: {
            Text(model.l.t("Recommended: the game's Documents folder. GameSaveSync gets one grant here and never touches anything outside the sync folder."))
        }
    }

    private var syncSection: some View {
        Section {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.l.t("Sync Folder"))
                        .font(.subheadline)
                    Text(syncPathDescription)
                        .font(.caption)
                        .foregroundStyle(accessRootURL == nil ? .secondary : .primary)
                        .lineLimit(3)
                }
                Spacer()
                Button(model.l.t("Choose…")) {
                    showsBrowser = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(accessRootURL == nil)
            }

            if accessRootURL != nil && syncRelativePath.isEmpty {
                Label {
                    Text(model.l.t("The whole authorised folder will be synced."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.footnote)
            }

            if existing?.accessRootIsLegacy == true {
                Text(model.l.t("This game was added before authorised folders existed, so its grant covers the save folder itself. Choose the game's Documents folder to sync a subfolder."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(model.l.t("Sync Folder"))
        } footer: {
            Text(model.l.t("Only this folder and its contents are synced. Other folders and files in the authorised folder are never uploaded or overwritten."))
        }
    }

    private var syncPathDescription: String {
        guard accessRootURL != nil || !accessRootHint.isEmpty else { return model.l.t("Choose an authorised folder first.") }
        let root = accessRootHint
        guard !syncRelativePath.isEmpty else { return root }
        return root.isEmpty ? syncRelativePath : "\(root) / \(syncRelativePath)"
    }

    // MARK: - Loading & saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard let existing else { return }
        name = existing.name
        gameId = existing.gameId
        accessRootHint = existing.accessRootHint
        syncRelativePath = existing.syncRelativePath
        idWasEdited = true
        // Resolving the root here lets the browser open without re-picking; it stays nil when the
        // grant is gone, and saving keeps the stored configuration untouched in that case.
        accessRootURL = model.resolveAccessRoot(for: existing)
    }

    private func save() {
        errorMessage = model.saveGame(existing: existing,
                                      name: name,
                                      gameId: gameId,
                                      accessRootURL: accessRootURL,
                                      syncRelativePath: syncRelativePath)
        if errorMessage == nil {
            dismiss()
        }
    }
}
