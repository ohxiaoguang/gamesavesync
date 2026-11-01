import Foundation
import SwiftUI
import Observation

@MainActor
@Observable
final class AppModel {
    // MARK: - Nested types

    struct Operation: Equatable {
        var gameId: UUID?
        var phase: SyncPhase?
        var title: String
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    struct ToastItem: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var symbol: String
    }

    struct ConflictRequest: Identifiable {
        let id = UUID()
        var game: Game
        var analysis: SyncAnalysis
    }

    /// A picked sync folder that does not live in iCloud Drive. Accepting it still works,
    /// but the backups stay on this device, so the user has to confirm first.
    struct CloudRootCandidate: Identifiable {
        let id = UUID()
        var url: URL
    }

    enum PendingAction: Equatable {
        case sync(UUID, SyncDirection)
        case upload(UUID)
        case restore(UUID)
        case restoreHistory(UUID, String)
        case restoreLocalBackup(UUID, String)

        var gameId: UUID {
            switch self {
            case .sync(let id, _), .upload(let id), .restore(let id),
                 .restoreHistory(let id, _), .restoreLocalBackup(let id, _):
                return id
            }
        }
    }

    struct ConfirmationRequest: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var confirmTitle: String
        var destructive: Bool
        var action: PendingAction
        var gameId: UUID
    }

    // MARK: - State

    let paths: AppPaths
    private let store: ConfigurationStore
    private let engine: SyncEngine

    private(set) var games: [Game] = []
    private(set) var settings = AppSettings()

    var analyses: [UUID: SyncAnalysis] = [:]
    var cloudHistory: [UUID: [CloudHistoryEntry]] = [:]
    var localBackups: [UUID: [LocalBackup]] = [:]
    var leftovers: [UUID: [DirectoryReplacer.Leftover]] = [:]

    var busy: Operation?
    var alertItem: AlertItem?
    var confirmation: ConfirmationRequest?
    var conflict: ConflictRequest?
    var pendingCloudRoot: CloudRootCandidate?
    var toast: ToastItem?
    var showCloudSetup = false
    var hasLoaded = false

    private var toastTask: Task<Void, Never>?

    // MARK: - Init

    init(paths: AppPaths = .launch()) {
        self.paths = paths
        self.store = ConfigurationStore(paths: paths)
        self.engine = SyncEngine(paths: paths)
        self.games = store.loadGames()
        self.settings = store.loadSettings()
    }

    var l: Localizer { settings.localizer }

    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await seedDemoDataIfRequested()
        if settings.cloudRootBookmark == nil {
            showCloudSetup = true
        }
        await refreshAll()
    }

    func refreshAll() async {
        for game in games {
            await refresh(game)
            loadHistory(for: game)
            loadLocalBackups(for: game)
            loadLeftovers(for: game)
        }
    }

    func refresh(_ game: Game) async {
        do {
            let analysis = try await withAccess(game: game) { [engine] request in
                engine.analyze(request)
            }
            analyses[game.id] = analysis
            persistDerivedTimestamps(from: analysis, for: game)
        } catch let error as SyncError {
            analyses[game.id] = SyncAnalysis(local: nil,
                                             localError: error,
                                             localFolderEmpty: false,
                                             remote: nil,
                                             remoteError: nil,
                                             decision: .blocked(error),
                                             localReadable: false)
        } catch {
            analyses[game.id] = SyncAnalysis(local: nil,
                                             localError: .generic(error.localizedDescription),
                                             localFolderEmpty: false,
                                             remote: nil,
                                             remoteError: nil,
                                             decision: .blocked(.generic(error.localizedDescription)),
                                             localReadable: false)
        }
    }

    private func persistDerivedTimestamps(from analysis: SyncAnalysis, for game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var changed = false
        let localTime = analysis.local?.newestModified
        let cloudTime = analysis.remote?.saveModifiedAt
        if games[index].lastLocalModified != localTime {
            games[index].lastLocalModified = localTime
            changed = true
        }
        if games[index].lastCloudModified != cloudTime {
            games[index].lastCloudModified = cloudTime
            changed = true
        }
        if changed { persistGames() }
    }

    func loadHistory(for game: Game) {
        guard settings.cloudRootBookmark != nil else { return }
        Task {
            if let entries = try? await withAccess(game: game, { [engine] request in
                engine.history(request)
            }) {
                cloudHistory[game.id] = entries
            }
        }
    }

    func loadLocalBackups(for game: Game) {
        localBackups[game.id] = engine.localBackups(gameId: game.gameId)
    }

    func loadLeftovers(for game: Game) {
        guard let access = try? resolveLocalAccess(for: game) else {
            leftovers[game.id] = []
            return
        }
        let scope = ScopedAccess(url: access.root)
        leftovers[game.id] = FileSystem.isDirectory(access.syncDirectory)
            ? DirectoryReplacer.leftovers(in: access.syncDirectory)
            : []
        scope.stop()
    }

    // MARK: - URL resolution

    /// Resolves the authorised root and the sync folder inside it.
    ///
    /// Only the root comes from the bookmark, so a game that deletes and recreates `saves` keeps
    /// working: the relative path is resolved against the current contents of the root.
    private func resolveLocalAccess(for game: Game) throws -> LocalAccess {
        let resolution: LocalAccessResolver.Resolution
        do {
            resolution = try LocalAccessResolver.resolve(game: game)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.accessRootUnavailable(detail: error.localizedDescription)
        }
        if resolution.bookmarkIsStale, let index = games.firstIndex(where: { $0.id == game.id }) {
            var updated = games[index]
            LocalAccessResolver.refreshBookmark(for: resolution.access, in: &updated)
            games[index] = updated
            persistGames()
        }
        return resolution.access
    }

    /// The authorised folder, for browsing subfolders in the editor.
    func resolveAccessRoot(for game: Game) -> URL? {
        (try? resolveLocalAccess(for: game))?.root
    }

    private func effectiveCloudRoot(from picked: URL) throws -> URL {
        let subpath = settings.cloudSubpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subpath.isEmpty else { return picked }
        if picked.lastPathComponent == subpath, FileSystem.isDirectory(picked) {
            return picked
        }
        let root = picked.appendingPathComponent(subpath, isDirectory: true)
        if !FileSystem.exists(root) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    /// Holds the security scopes for the local folder and the cloud folder for the whole
    /// operation, then runs the work off the main actor.
    private func withAccess<T>(game: Game, _ work: @escaping @Sendable (SyncRequest) throws -> T) async throws -> T {
        let access = try resolveLocalAccess(for: game)
        guard let cloudBookmark = settings.cloudRootBookmark else {
            throw SyncError.cloudRootUnavailable
        }
        let cloudResolved: (url: URL, isStale: Bool)
        do {
            cloudResolved = try DirectoryAccessManager.resolve(cloudBookmark)
        } catch {
            throw SyncError.cloudRootUnavailable
        }

        // The scope covers the authorised root; the sync folder inherits it.
        let localScope = ScopedAccess(url: access.root)
        let cloudScope = ScopedAccess(url: cloudResolved.url)
        defer {
            localScope.stop()
            cloudScope.stop()
        }

        let cloudRoot: URL
        do {
            cloudRoot = try effectiveCloudRoot(from: cloudResolved.url)
        } catch {
            throw SyncError.folderCreationFailed(error.localizedDescription)
        }

        if cloudResolved.isStale, let data = try? DirectoryAccessManager.bookmark(for: cloudResolved.url) {
            settings.cloudRootBookmark = data
            try? store.saveSettings(settings)
        }

        let request = SyncRequest(gameId: game.gameId,
                                  gameName: game.name,
                                  localDirectory: access.syncDirectory,
                                  accessRoot: access.root,
                                  syncRelativePath: access.relativePath,
                                  cloudRoot: cloudRoot,
                                  retention: settings.historyRetention,
                                  deviceName: settings.deviceName,
                                  appVersion: Self.appVersion,
                                  hasSyncedBefore: game.lastSync?.isSuccess == true,
                                  progress: progressHandler())

        return try await Task.detached(priority: .userInitiated) {
            try work(request)
        }.value
    }

    private func progressHandler() -> @Sendable (SyncPhase) -> Void {
        { [weak self] phase in
            Task { @MainActor in
                self?.busy?.phase = phase
            }
        }
    }

    // MARK: - Cloud root

    var cloudRootConfigured: Bool { settings.cloudRootBookmark != nil }

    /// Called when the user picks a folder. Folders outside iCloud Drive are not rejected, but
    /// they are not shared with other devices, so they need an explicit confirmation.
    func setCloudRoot(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let inICloud = ICloudSupport.isInICloudDrive(url)
        if scoped { url.stopAccessingSecurityScopedResource() }

        if inICloud {
            applyCloudRoot(url)
        } else {
            pendingCloudRoot = CloudRootCandidate(url: url)
        }
    }

    /// The user explicitly accepted a folder that is not inside iCloud Drive.
    func usePendingCloudRootAnyway() {
        guard let candidate = pendingCloudRoot else { return }
        pendingCloudRoot = nil
        applyCloudRoot(candidate.url)
    }

    func cancelPendingCloudRoot() {
        pendingCloudRoot = nil
    }

    private func applyCloudRoot(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try DirectoryAccessManager.bookmark(for: url)
            settings.cloudRootBookmark = bookmark
            settings.cloudRootHint = PathHint.describe(url)
            settings.cloudRootIsICloud = ICloudSupport.isInICloudDrive(url)
            // Creating the subfolder now surfaces a permission problem immediately.
            _ = try effectiveCloudRoot(from: url)
            try store.saveSettings(settings)
            showCloudSetup = false
            showToast(ToastItem(text: l.t("Configured"), symbol: "checkmark.icloud"))
            Task { await refreshAll() }
        } catch {
            alertItem = AlertItem(title: l.t("Error"), message: error.localizedDescription)
        }
    }

    func cloudRootDescription() -> String {
        guard let hint = settings.cloudRootHint else { return l.t("Not configured") }
        return hint
    }

    // MARK: - Game management

    /// Returns a localized error message, or nil on success.
    ///
    /// `accessRootURL` is only set when the user picked a new authorised folder in this session;
    /// `syncRelativePath` is always the folder inside that root that should be synced.
    func saveGame(existing: Game?,
                  name: String,
                  gameId: String,
                  accessRootURL: URL?,
                  syncRelativePath: String) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedId = Slugger.sanitizeGameId(gameId.trimmingCharacters(in: .whitespacesAndNewlines))

        guard !trimmedName.isEmpty else { return l.t("Enter a game name.") }
        guard Slugger.isValidGameId(trimmedId) else {
            return l.t("Used to match backups between devices. Letters, numbers, dots and dashes.")
        }
        guard let relativePath = SyncPath.normalize(syncRelativePath) else {
            return l.t("The save folder is outside the authorised folder.")
        }
        if games.contains(where: { $0.gameId == trimmedId && $0.id != existing?.id }) {
            return l.t("A game with this ID already exists.")
        }

        // A new grant has to be bookmarked and sanity-checked before anything is stored.
        var newBookmark: Data?
        if let accessRootURL {
            let scoped = accessRootURL.startAccessingSecurityScopedResource()
            defer { if scoped { accessRootURL.stopAccessingSecurityScopedResource() } }
            guard FileSystem.isDirectory(accessRootURL) else {
                return l.t("The selected folder is no longer available. Pick it again in the game settings.")
            }
            if !relativePath.isEmpty {
                do {
                    _ = try SyncPath.resolve(root: accessRootURL, relativePath: relativePath)
                } catch {
                    return l.t("The save folder is outside the authorised folder.")
                }
            }
            guard let data = try? DirectoryAccessManager.bookmark(for: accessRootURL) else {
                return l.t("The selected folder is no longer available. Pick it again in the game settings.")
            }
            newBookmark = data
        }

        if let existing {
            guard var updated = games.first(where: { $0.id == existing.id }) else { return nil }
            updated.name = trimmedName
            updated.gameId = trimmedId
            updated.updatedAt = Date()
            if let newBookmark, let accessRootURL {
                // Re-picking the folder is what lifts a legacy grant up to `Documents`.
                updated.accessRootBookmark = newBookmark
                updated.accessRootHint = PathHint.describe(accessRootURL)
                updated.accessRootIsLegacy = false
            }
            updated.syncRelativePath = relativePath
            if let index = games.firstIndex(where: { $0.id == existing.id }) {
                games[index] = updated
            }
            persistGames()
            Task { await refresh(updated) }
            return nil
        }

        guard let newBookmark, let accessRootURL else { return l.t("Choose an authorised folder first.") }

        let game = Game(name: trimmedName,
                        gameId: trimmedId,
                        accessRootBookmark: newBookmark,
                        accessRootHint: PathHint.describe(accessRootURL),
                        syncRelativePath: relativePath)
        games.append(game)
        persistGames()
        Task { await refresh(game) }
        return nil
    }

    func deleteGame(_ game: Game) {
        games.removeAll { $0.id == game.id }
        analyses[game.id] = nil
        cloudHistory[game.id] = nil
        localBackups[game.id] = nil
        leftovers[game.id] = nil
        persistGames()
    }

    private func persistGames() {
        do {
            try store.saveGames(games)
        } catch {
            Log.write("failed to save games.json: \(error.localizedDescription)")
        }
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        do {
            try store.saveSettings(settings)
        } catch {
            Log.write("failed to save settings.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Operations

    func isBusy(_ game: Game) -> Bool {
        busy?.gameId == game.id
    }

    var isBusyAtAll: Bool { busy != nil }

    func sync(_ game: Game) {
        guard busy == nil else { return }
        Task { await runSync(game) }
    }

    private func runSync(_ game: Game) async {
        busy = Operation(gameId: game.id, phase: .readingManifest, title: l.t("Sync"))
        do {
            let analysis = try await withAccess(game: game) { [engine] request in
                engine.analyze(request)
            }
            analyses[game.id] = analysis

            switch analysis.decision {
            case .blocked(let error):
                busy = nil
                present(error)
                return
            case .conflict:
                busy = nil
                conflict = ConflictRequest(game: game, analysis: analysis)
                return
            case .upToDate:
                busy = nil
                let report = SyncReport(outcome: .upToDate,
                                        files: analysis.local?.fileCount ?? 0,
                                        bytes: analysis.local?.totalBytes ?? 0)
                apply(report: report, to: game)
                return
            case .upload, .download:
                guard let direction = analysis.decision.direction else {
                    busy = nil
                    return
                }
                if analysis.confirmation != .none {
                    busy = nil
                    confirmation = makeConfirmation(for: analysis, game: game, action: .sync(game.id, direction))
                    return
                }
                busy = nil
                await execute(.sync(game.id, direction), game: game)
            }
        } catch let error as SyncError {
            busy = nil
            present(error)
        } catch {
            busy = nil
            present(.generic(error.localizedDescription))
        }
    }

    /// Runs an operation that the user already approved.
    func execute(_ action: PendingAction, game: Game) async {
        guard busy == nil else { return }
        guard games.contains(where: { $0.id == game.id }) else { return }
        busy = Operation(gameId: game.id, phase: nil, title: l.t("Sync"))

        do {
            let report: SyncReport
            switch action {
            case .sync(_, let direction):
                switch direction {
                case .upload:
                    report = try await withAccess(game: game) { [engine] request in try engine.upload(request) }
                case .download:
                    report = try await withAccess(game: game) { [engine] request in try engine.restore(request) }
                }
            case .upload:
                report = try await withAccess(game: game) { [engine] request in try engine.upload(request) }
            case .restore:
                report = try await withAccess(game: game) { [engine] request in try engine.restore(request) }
            case .restoreHistory(_, let versionId):
                report = try await withAccess(game: game) { [engine] request in
                    try engine.restoreHistory(request, versionId: versionId)
                }
            case .restoreLocalBackup(_, let backupId):
                guard let backup = engine.localBackups(gameId: game.gameId).first(where: { $0.id == backupId }) else {
                    throw SyncError.generic("That backup no longer exists.")
                }
                report = try await withAccess(game: game) { [engine] request in
                    try engine.restoreLocalBackup(request, backup: backup)
                }
            }
            await refresh(game)
            apply(report: report, to: game)
            loadHistory(for: game)
            loadLocalBackups(for: game)
            loadLeftovers(for: game)
        } catch let error as SyncError {
            present(error)
        } catch {
            present(.generic(error.localizedDescription))
        }
        busy = nil
    }

    private func apply(report: SyncReport, to game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        let kind = report.outcome.recordKind
        games[index].lastSync = SyncRecord(kind: kind,
                                           fileCount: report.files,
                                           totalBytes: report.bytes)
        persistGames()

        let text: String
        let symbol: String
        switch report.outcome {
        case .uploaded:
            text = l.t("Uploaded"); symbol = "arrow.up.circle.fill"
        case .uploadedPendingICloud:
            text = l.t("Uploaded (waiting for iCloud)"); symbol = "clock.badge.checkmark"
        case .restored:
            text = l.t("Restored"); symbol = "arrow.down.circle.fill"
        case .restoredHistory:
            text = l.t("Restored from history"); symbol = "clock.arrow.circlepath"
        case .upToDate:
            text = l.t("Already up to date"); symbol = "checkmark.circle.fill"
        case .nothingToDo, .conflictPending:
            text = l.t("No changes were made."); symbol = "info.circle"
        }
        showToast(ToastItem(text: text, symbol: symbol))
    }

    private func present(_ error: SyncError) {
        alertItem = AlertItem(title: l.t("Error"), message: error.localized(l))
        Log.persist("error: \(error.messageKey) \(error.detail ?? "")", to: paths.logs)
    }

    func showToast(_ item: ToastItem) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = item }
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.25)) { self.toast = nil }
        }
    }

    // MARK: - Confirmations

    private func makeConfirmation(for analysis: SyncAnalysis, game: Game, action: PendingAction) -> ConfirmationRequest {
        let direction = analysis.decision.direction ?? .download
        let closeGame = l.t("Close the game before syncing. GameSaveSync backs up your current saves, then replaces the folder you selected.")
        let safety = l.t("An automatic backup of the version being replaced is created first.")

        switch analysis.confirmation {
        case .sameTimeConflict:
            return ConfirmationRequest(title: l.t("Needs attention"),
                                       message: closeGame,
                                       confirmTitle: l.t("Continue"),
                                       destructive: true,
                                       action: action,
                                       gameId: game.id)
        case .firstSyncOverwrite(let dir):
            let message = dir == .upload
                ? "\(closeGame)\n\n\(l.t("This will replace the cloud backup with your local saves."))\n\(safety)"
                : "\(closeGame)\n\n\(l.t("This will replace your local saves with the cloud backup."))\n\(safety)"
            return ConfirmationRequest(title: dir == .upload ? l.t("Upload now?") : l.t("Restore now?"),
                                       message: message,
                                       confirmTitle: dir == .upload ? l.t("Upload") : l.t("Restore"),
                                       destructive: true,
                                       action: action,
                                       gameId: game.id)
        case .emptyLocalWillBeFilled:
            return ConfirmationRequest(title: l.t("Restore now?"),
                                       message: "\(closeGame)\n\n\(l.t("The local folder is empty. Restoring will fill it with the cloud backup."))",
                                       confirmTitle: l.t("Restore"),
                                       destructive: false,
                                       action: action,
                                       gameId: game.id)
        case .clockSkew(let dir):
            let message = "\(closeGame)\n\n\(l.t("The timestamps are far apart. Check that the clock on both devices is correct."))"
            return ConfirmationRequest(title: dir == .upload ? l.t("Upload now?") : l.t("Restore now?"),
                                       message: message,
                                       confirmTitle: dir == .upload ? l.t("Upload") : l.t("Restore"),
                                       destructive: true,
                                       action: action,
                                       gameId: game.id)
        case .none:
            return ConfirmationRequest(title: l.t("Continue"),
                                       message: closeGame,
                                       confirmTitle: l.t("Continue"),
                                       destructive: false,
                                       action: action,
                                       gameId: game.id)
        }
    }

    func requestUpload(_ game: Game) {
        guard busy == nil else { return }
        confirmation = ConfirmationRequest(
            title: l.t("Upload (Overwrite Cloud)"),
            message: "\(l.t("This will replace the cloud backup with your local saves."))\n\(l.t("An automatic backup of the version being replaced is created first."))",
            confirmTitle: l.t("Upload"),
            destructive: true,
            action: .upload(game.id),
            gameId: game.id)
    }

    func requestRestore(_ game: Game) {
        guard busy == nil else { return }
        confirmation = ConfirmationRequest(
            title: l.t("Restore (Overwrite Local)"),
            message: "\(l.t("This will replace your local saves with the cloud backup."))\n\(l.t("An automatic backup of the version being replaced is created first."))",
            confirmTitle: l.t("Restore"),
            destructive: true,
            action: .restore(game.id),
            gameId: game.id)
    }

    func requestRestoreHistory(_ game: Game, entry: CloudHistoryEntry) {
        guard busy == nil else { return }
        confirmation = ConfirmationRequest(
            title: l.t("Restore This Version"),
            message: "\(DateText.dayTime(entry.backupCreatedAt, language: l.language))\n\n\(l.t("This will replace your local saves with the cloud backup."))\n\(l.t("An automatic backup of the version being replaced is created first."))",
            confirmTitle: l.t("Restore"),
            destructive: true,
            action: .restoreHistory(game.id, entry.versionId),
            gameId: game.id)
    }

    func requestRestoreLocalBackup(_ game: Game, backup: LocalBackup) {
        guard busy == nil else { return }
        confirmation = ConfirmationRequest(
            title: l.t("Restore This Version"),
            message: "\(DateText.dayTime(backup.createdAt, language: l.language))\n\n\(l.t("This will replace your local saves with the cloud backup."))",
            confirmTitle: l.t("Restore"),
            destructive: true,
            action: .restoreLocalBackup(game.id, backup.id),
            gameId: game.id)
    }

    func confirm(_ request: ConfirmationRequest) {
        confirmation = nil
        guard let game = games.first(where: { $0.id == request.gameId }) else { return }
        let action = request.action
        Task { await execute(action, game: game) }
    }

    func resolveConflict(useLocal: Bool, request: ConflictRequest) {
        conflict = nil
        guard let game = games.first(where: { $0.id == request.game.id }) else { return }
        let action: PendingAction = useLocal ? .upload(game.id) : .restore(game.id)
        Task { await execute(action, game: game) }
    }

    // MARK: - Development seeding

    /// Fills the app with sample games when launched with `-GSSDemoSeed`.
    /// Used by the UI tests and for manual layout checks; it is inert otherwise.
    func seedDemoDataIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-GSSDemoSeed") else { return }
        let fm = FileManager.default
        let base = paths.container.appendingPathComponent("Demo", isDirectory: true)

        // Start from a clean demo state so repeated runs (and UI tests) are deterministic.
        try? fm.removeItem(at: base)
        games.removeAll()
        settings.cloudRootBookmark = nil
        settings.cloudRootHint = nil

        let cloud = base.appendingPathComponent("GameSaveSync", isDirectory: true)
        try? fm.createDirectory(at: cloud, withIntermediateDirectories: true)

        if let data = try? DirectoryAccessManager.bookmark(for: cloud) {
            settings.cloudRootBookmark = data
            settings.cloudRootHint = "GameSaveSync (Demo)"
            settings.cloudRootIsICloud = false
            try? store.saveSettings(settings)
        }

        struct Spec {
            let name: String
            let gameId: String
            let files: [String: String]
            let daysAgo: Double
            let upload: Bool
            let mode: Mode
            enum Mode { case untouched, cloudNewer, conflict, confirmDownload }
        }

        let specs: [Spec] = [
            Spec(name: "Darkest Dungeon", gameId: "darkest-dungeon",
                 files: ["profile/persist.game.json": "{\"heroes\":12}",
                         "saves/run-1.sav": String(repeating: "A", count: 4096)],
                 daysAgo: 1.5, upload: false, mode: .untouched),
            Spec(name: "FC 27", gameId: "fc-27",
                 files: ["career/save1.bin": String(repeating: "B", count: 8192),
                         "settings.ini": "resolution=1920x1080"],
                 daysAgo: 0.4, upload: true, mode: .cloudNewer),
            Spec(name: "Mario Wonder", gameId: "mario-wonder",
                 files: ["save.dat": String(repeating: "C", count: 2048)],
                 daysAgo: 2.2, upload: true, mode: .untouched),
            Spec(name: "Hollow Knight", gameId: "hollow-knight",
                 files: ["user1.dat": "knight-a"],
                 daysAgo: 0.9, upload: true, mode: .conflict),
            Spec(name: "Stardew Valley", gameId: "stardew-valley",
                 files: ["save/world1.dat": "farm-a"],
                 daysAgo: 3.5, upload: true, mode: .confirmDownload),
        ]

        for spec in specs {
            // Mirror a real game container: the authorised root is `Documents`, the saves live in
            // `Documents/saves`, and unrelated folders sit next to them.
            let root = base.appendingPathComponent("Saves/\(spec.gameId)/Documents", isDirectory: true)
            let folder = root.appendingPathComponent("saves", isDirectory: true)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try? fm.createDirectory(at: root.appendingPathComponent("cache", isDirectory: true), withIntermediateDirectories: true)
            try? Data("{\"volume\":0.8}".utf8).write(to: root.appendingPathComponent("config.json"))
            let stamp = Date().addingTimeInterval(-spec.daysAgo * 86_400)
            for (path, contents) in spec.files {
                let url = folder.appendingPathComponent(path)
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(contents.utf8).write(to: url)
                try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
            }
            guard let bookmark = try? DirectoryAccessManager.bookmark(for: root) else { continue }
            let game = Game(name: spec.name,
                            gameId: spec.gameId,
                            accessRootBookmark: bookmark,
                            accessRootHint: PathHint.describe(root),
                            syncRelativePath: "saves")
            games.append(game)

            guard spec.upload else { continue }
            let request = SyncRequest(gameId: game.gameId,
                                      gameName: game.name,
                                      localDirectory: folder,
                                      accessRoot: root,
                                      syncRelativePath: "saves",
                                      cloudRoot: cloud,
                                      retention: 3,
                                      deviceName: settings.deviceName,
                                      appVersion: Self.appVersion,
                                      hasSyncedBefore: false)
            if let report = try? engine.upload(request),
               spec.mode != .confirmDownload,
               let index = games.firstIndex(where: { $0.id == game.id }) {
                games[index].lastSync = SyncRecord(kind: report.outcome.recordKind,
                                                   fileCount: report.files,
                                                   totalBytes: report.bytes)
            }

            switch spec.mode {
            case .untouched:
                break
            case .cloudNewer:
                // Every local file older than the cloud backup, so the newest local time moves back.
                for (path, contents) in spec.files {
                    let url = folder.appendingPathComponent(path)
                    try? Data((contents + "-unused-local-edit").utf8).write(to: url)
                    try? fm.setAttributes([.modificationDate: stamp.addingTimeInterval(-7200)], ofItemAtPath: url.path)
                }
            case .confirmDownload:
                // Cloud exists, this device never synced, local copy is older.
                for (path, contents) in spec.files {
                    let url = folder.appendingPathComponent(path)
                    try? Data((contents + "-older").utf8).write(to: url)
                    try? fm.setAttributes([.modificationDate: stamp.addingTimeInterval(-86_400)], ofItemAtPath: url.path)
                }
            case .conflict:
                // Same timestamp, different bytes: must never be resolved automatically.
                let url = folder.appendingPathComponent("user1.dat")
                try? Data("knight-b".utf8).write(to: url)
                try? fm.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
            }
        }
        persistGames()

    }

    // MARK: - Recovery

    func recoverLeftover(_ leftover: DirectoryReplacer.Leftover, for game: Game) async {
        guard let access = try? resolveLocalAccess(for: game) else {
            alertItem = AlertItem(title: l.t("Error"), message: l.t("The selected folder is no longer available. Pick it again in the game settings."))
            return
        }
        let scope = ScopedAccess(url: access.root)
        defer { scope.stop() }
        do {
            try DirectoryReplacer.restoreLeftover(leftover, into: access.syncDirectory)
            showToast(ToastItem(text: l.t("Recovered previous saves."), symbol: "clock.arrow.circlepath"))
            loadLeftovers(for: game)
            await refresh(game)
        } catch let error as SyncError {
            present(error)
        } catch {
            present(.generic(error.localizedDescription))
        }
    }

    func discardLeftover(_ leftover: DirectoryReplacer.Leftover, for game: Game) {
        DirectoryReplacer.discardLeftover(leftover)
        loadLeftovers(for: game)
    }
}
