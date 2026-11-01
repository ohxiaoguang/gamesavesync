import SwiftUI
import UniformTypeIdentifiers

/// Browses the subfolders of the authorised root and returns a path relative to it.
///
/// Only folders inside `root` can be reached: the list is built with `SyncPath.subdirectories`,
/// which skips symlinks and hidden entries, and the result is a relative path, so no URL outside
/// the authorised root is ever stored.
struct SyncFolderBrowserView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let root: URL
    private let onPick: (String) -> Void
    @State private var path: [String]
    @State private var phases: [String: SubfolderRows.Phase] = [:]
    @State private var attempts: [String: Int] = [:]
    @State private var showsSystemPicker = false
    @State private var pickError: String?
    @State private var pendingPick: ScopedAccess?
    @State private var pickTask: Task<Void, Never>?

    init(root: URL, initialPath: String, onPick: @escaping (String) -> Void) {
        self.root = root
        self.onPick = onPick
        let components = initialPath.split(separator: "/").map(String.init)
        _path = State(initialValue: components.indices.map { components[...$0].joined(separator: "/") })
    }

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            macBrowser
            #else
            NavigationStack(path: $path) {
                level(path: [])
                    .navigationTitle(model.l.t("Sync Folder"))
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar { toolbar(for: []) }
                    .navigationDestination(for: String.self) { relative in
                        let childPath = relative.split(separator: "/").map(String.init)
                        level(path: childPath)
                            .navigationTitle(childPath.last ?? "")
                            #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            #endif
                            .toolbar { toolbar(for: childPath) }
                    }
            }
            #endif
        }
        #if os(macOS)
        .frame(width: 620, height: 540)
        #endif
        .onDisappear { pickTask?.cancel() }
        #if os(iOS)
        .sheet(isPresented: $showsSystemPicker, onDismiss: {
            guard let access = pendingPick else { return }
            pendingPick = nil
            handlePicked(.success([access.url]), holding: access)
        }) {
            FolderPickerSheet(directoryURL: root, onPick: { url in
                // Retain access until validation has completed after the picker dismisses.
                pendingPick = ScopedAccess(url: url)
                showsSystemPicker = false
            }, onCancel: {
                pendingPick = nil
                showsSystemPicker = false
            })
            .ignoresSafeArea()
        }
        #endif
        .alert(model.l.t("Could not select this folder."),
               isPresented: Binding(get: { pickError != nil }, set: { if !$0 { pickError = nil } })) {
            Button(model.l.t("OK, understood"), role: .cancel) { pickError = nil }
        } message: {
            Text(pickError ?? "")
        }
    }

    #if os(macOS)
    private var macBrowser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    if !path.isEmpty { path.removeLast() }
                } label: {
                    Label(model.l.t("Parent Folder"), systemImage: "chevron.left")
                }
                .disabled(path.isEmpty)
                Text(model.l.t("Sync Folder"))
                    .font(.headline)
                Spacer()
            }
            .padding(16)

            Divider()
            level(path: (path.last ?? "").split(separator: "/").map(String.init))
                .listStyle(.inset)
            Divider()

            HStack {
                Button(model.l.t("Choose with Finder…")) { chooseMacFolder() }
                Spacer()
                Button(model.l.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(model.l.t("Choose This Folder")) {
                    onPick(path.last ?? "")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
    }

    private func chooseMacFolder() {
        let scope = ScopedAccess(url: root)
        let directory = root.appendingPathComponent(path.last ?? "", isDirectory: true)
        FolderPickerSheet.chooseDirectory(directoryURL: directory, localizer: model.l) { url in
            defer { scope.stop() }
            guard let url else { return }
            handlePicked(.success([url]), holding: ScopedAccess(url: url))
        }
    }
    #endif

    // MARK: - Pieces

    @ToolbarContentBuilder
    private func toolbar(for path: [String]) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(model.l.t("Cancel")) { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(model.l.t("Choose This Folder")) {
                onPick(path.joined(separator: "/"))
                dismiss()
            }
        }
    }

    private func level(path components: [String]) -> some View {
        let relativePath = components.joined(separator: "/")
        let isRoot = components.isEmpty

        return List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(displayPath(relativePath))
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            } header: {
                Text(model.l.t("Authorised Folder"))
            }

            Section {
                SubfolderRows(relativePath: relativePath,
                              phase: phases[relativePath] ?? .loading,
                              retry: { attempts[relativePath, default: 0] += 1 },
                              openFolder: { path.append($0) })
            } header: {
                Text(model.l.t("Subfolders"))
            }

            Section {
                if isRoot {
                    Label {
                        Text(model.l.t("Choosing this folder syncs everything inside the authorised folder."))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                } else {
                    Text(model.l.t("Only this folder and its contents are synced. The rest of the authorised folder is left alone."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if os(iOS)
                // The Files app enumerates through its own process, so it still works when this
                // app cannot read the folder itself.
                Button {
                    showsSystemPicker = true
                } label: {
                    Label(model.l.t("Choose with the Files app…"), systemImage: "folder.badge.questionmark")
                        .font(.footnote)
                }
                #endif
            }
        }
        // Attach work to the stable List, not a Group whose children change with its phase.
        // A task on that Group is recreated as loading rows become folder links.
        .task(id: "\(relativePath):\(attempts[relativePath, default: 0])") {
            await load(relativePath: relativePath)
        }
    }

    private func displayPath(_ relativePath: String) -> String {
        let rootName = PathHint.describe(root)
        return relativePath.isEmpty ? rootName : "\(rootName) / \(relativePath)"
    }

    @MainActor
    private func load(relativePath: String) async {
        phases[relativePath] = .loading
        let root = self.root
        do {
            let children = try await BrowserFileOperation.run {
                let scope = ScopedAccess(url: root)
                defer { scope.stop() }
                let directory = try SyncPath.resolve(root: root, relativePath: relativePath)
                return try SyncPath.subdirectories(of: directory)
            }
            phases[relativePath] = .loaded(children)
        } catch is CancellationError {
            return
        } catch BrowserFileOperation.Failure.timedOut {
            Log.write("browser timed out listing \(relativePath.isEmpty ? "<root>" : relativePath)")
            phases[relativePath] = .timedOut
        } catch {
            Log.write("browser could not list \(relativePath.isEmpty ? "<root>" : relativePath): \(error.localizedDescription)")
            phases[relativePath] = .failed(error.localizedDescription)
        }
    }

    /// Turns a folder picked in the Files app into a path relative to the authorised root.
    private func handlePicked(_ result: Result<[URL], Error>, holding pickedScope: ScopedAccess? = nil) {
        switch result {
        case .success(let urls):
            guard let picked = urls.first else { return }
            pickTask?.cancel()
            let root = self.root
            pickTask = Task { @MainActor in
                do {
                    let relative = try await BrowserFileOperation.run {
                        let rootAccess = ScopedAccess(url: root)
                        let pickedAccess = ScopedAccess(url: picked)
                        defer {
                            pickedScope?.stop()
                            pickedAccess.stop()
                            rootAccess.stop()
                        }
                        return try SyncPath.relativePath(of: picked, inside: root)
                    }
                    onPick(relative)
                    dismiss()
                } catch is CancellationError {
                    return
                } catch BrowserFileOperation.Failure.timedOut {
                    pickError = model.l.t("Reading this folder timed out.")
                } catch {
                    pickError = model.l.t("Pick a folder inside the authorised folder.")
                }
            }
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError { return }
            pickError = error.localizedDescription
        }
    }
}

/// Renders one level without owning tasks: loading must live on the stable enclosing List,
/// because the rows in this Group are replaced when the phase changes.
private struct SubfolderRows: View {
    @Environment(AppModel.self) private var model

    let relativePath: String
    let phase: Phase
    let retry: () -> Void
    let openFolder: (String) -> Void

    enum Phase {
        case loading
        case loaded([URL])
        case failed(String)
        case timedOut
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.l.t("Reading…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .timedOut:
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(model.l.t("Reading this folder timed out."))
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    Text(model.l.t("iCloud or the file provider did not answer. You can try again, or choose the folder that is already authorised."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    retryButton
                }
            case .failed(let detail):
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text(model.l.t("Could not read this folder."))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    retryButton
                }
            case .loaded(let children):
                if children.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.l.t("There are no subfolders here."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(model.l.t("You can choose this folder itself."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(children, id: \.lastPathComponent) { child in
                        let target = relativePath.isEmpty ? child.lastPathComponent : relativePath + "/" + child.lastPathComponent
                        #if os(macOS)
                        Button {
                            openFolder(target)
                        } label: {
                            HStack(spacing: 10) {
                                Label(child.lastPathComponent, systemImage: "folder")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        #else
                        NavigationLink(value: target) {
                            Label(child.lastPathComponent, systemImage: "folder")
                                .lineLimit(1)
                        }
                        #endif
                    }
                }
            }
        }
    }

    private var retryButton: some View {
        Button(model.l.t("Try Again")) {
            retry()
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}
