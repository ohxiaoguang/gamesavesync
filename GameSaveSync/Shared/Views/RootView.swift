import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    @State private var showAddGame = false
    @State private var showSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        @Bindable var model = model

        NavigationStack(path: $path) {
            List {
                if !model.cloudRootConfigured {
                    cloudBanner
                }

                if let operation = model.busy {
                    operationRow(operation)
                }

                if model.games.isEmpty {
                    EmptyGamesView(localizer: model.l) { showAddGame = true }
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(model.games) { game in
                            GameRowLink(game: game)
                        }
                    } header: {
                        Text(model.l.t("Games"))
                    } footer: {
                        Text(model.l.t("Everything runs on this device. Saves are copied to the iCloud Drive folder you picked."))
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("GameSaveSync")
            .navigationDestination(for: UUID.self) { id in
                GameDetailView(gameId: id)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAddGame = true
                    } label: {
                        Label(model.l.t("Add Game"), systemImage: "plus")
                    }
                    .disabled(model.isBusyAtAll)
                }
                ToolbarItem(placement: .automatic) {
                    Button {
                        showSettings = true
                    } label: {
                        Label(model.l.t("Settings"), systemImage: "gearshape")
                    }
                }
            }
            .refreshable {
                await model.refreshAll()
            }
        }
        .sheet(isPresented: $showAddGame) {
            GameEditorView(gameID: nil)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showCloudSetup) {
            CloudSetupView(isInitialSetup: true)
                .interactiveDismissDisabled(model.games.isEmpty)
        }
        .sheet(item: $model.conflict) { request in
            ConflictView(request: request)
        }
        .alert(item: $model.alertItem) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text(model.l.t("OK"))))
        }
        .alert(model.confirmation?.title ?? model.l.t("Continue"), isPresented: confirmationBinding, presenting: model.confirmation) { request in
            Button(request.confirmTitle, role: request.destructive ? .destructive : nil) {
                model.confirm(request)
            }
            Button(model.l.t("Cancel"), role: .cancel) {
                model.confirmation = nil
            }
        } message: { request in
            Text(request.message)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(item: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .task {
            await model.bootstrap()
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.confirmation != nil },
                set: { if !$0 { model.confirmation = nil } })
    }

    private var cloudBanner: some View {
        Section {
            Button {
                model.showCloudSetup = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.l.t("Configure iCloud Drive first"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(model.l.t("Choose a folder inside iCloud Drive, for example iCloud Drive/GameSaveSync."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func operationRow(_ operation: AppModel.Operation) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title)
                        .font(.subheadline.weight(.medium))
                    Text(model.l.t(operation.phase?.text ?? "Checking…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

struct GameRowLink: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        HStack(spacing: 12) {
            NavigationLink(value: game.id) {
                HStack(spacing: 12) {
                    GameGlyph(name: game.name)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(game.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let presentation = model.analyses[game.id]?.presentation(game: game, localizer: model.l) {
                            StatusPill(presentation: presentation)
                        } else {
                            StatusPill(presentation: StatusPresentation(text: model.l.t("Checking…"),
                                                                        symbol: "hourglass",
                                                                        tint: .secondary,
                                                                        detail: nil))
                        }
                    }
                }
            }

            if model.isBusy(game) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 32, height: 32)
            } else {
                Button {
                    model.sync(game)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusyAtAll)
                .accessibilityLabel(model.l.t("Sync"))
            }
        }
    }
}

struct GameGlyph: View {
    let name: String

    var body: some View {
        let letter = String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                                 startPoint: .topLeading,
                                 endPoint: .bottomTrailing))
            .frame(width: 38, height: 38)
            .overlay {
                Text(letter.isEmpty ? "?" : letter)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}
