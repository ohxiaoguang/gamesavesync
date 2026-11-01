import SwiftUI

struct StatusPresentation {
    var text: String
    var symbol: String
    var tint: Color
    var detail: String?
}

extension SyncAnalysis {
    func presentation(game: Game, localizer: Localizer) -> StatusPresentation {
        // A blocked decision already carries the most useful explanation.
        if case .blocked(let error) = decision {
            if case .localFolderUnavailable = error {
                return StatusPresentation(text: localizer.t("Folder access lost"),
                                          symbol: "folder.badge.questionmark",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .accessRootUnavailable = error {
                return StatusPresentation(text: localizer.t("Folder access lost"),
                                          symbol: "folder.badge.questionmark",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .accessRootMissing = error {
                return StatusPresentation(text: localizer.t("Authorised folder missing"),
                                          symbol: "folder.badge.minus",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .syncFolderMissing = error {
                return StatusPresentation(text: localizer.t("Save folder missing"),
                                          symbol: "folder.badge.questionmark",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .invalidSyncPath = error {
                return StatusPresentation(text: localizer.t("Save folder outside the authorised folder"),
                                          symbol: "exclamationmark.triangle.fill",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .gitHubNotConfigured = error {
                return StatusPresentation(text: localizer.t("Connect a GitHub repository"),
                                          symbol: "arrow.triangle.branch",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .cloudBackupIncomplete = error {
                return StatusPresentation(text: localizer.t("Remote save incomplete"),
                                          symbol: "exclamationmark.arrow.triangle.2.circlepath",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .cloudBackupMissing = error {
                return StatusPresentation(text: localizer.t("No remote save yet"),
                                          symbol: "arrow.triangle.branch",
                                          tint: .secondary,
                                          detail: nil)
            }
            if case .gitHubAuthFailed = error {
                return StatusPresentation(text: localizer.t("Token rejected"),
                                          symbol: "key.slash",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .gitHubPermissionDenied = error {
                return StatusPresentation(text: localizer.t("Missing permission"),
                                          symbol: "lock.slash",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .gitHubRateLimited = error {
                return StatusPresentation(text: localizer.t("Rate limited"),
                                          symbol: "hourglass",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .gitHubRepositoryNotFound = error {
                return StatusPresentation(text: localizer.t("Repository not found"),
                                          symbol: "questionmark.folder",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .gitHubRepositoryNotPrivate = error {
                return StatusPresentation(text: localizer.t("Repository is not private"),
                                          symbol: "lock.open",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .gitHubBranchMissing = error {
                return StatusPresentation(text: localizer.t("Branch not found"),
                                          symbol: "arrow.triangle.branch",
                                          tint: .red,
                                          detail: error.localized(localizer))
            }
            if case .gitHubRemoteChanged = error {
                return StatusPresentation(text: localizer.t("Remote version changed"),
                                          symbol: "arrow.triangle.2.circlepath",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .networkUnavailable = error {
                return StatusPresentation(text: localizer.t("Offline"),
                                          symbol: "wifi.slash",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            if case .networkTimeout = error {
                return StatusPresentation(text: localizer.t("Connection timed out"),
                                          symbol: "clock.badge.exclamationmark",
                                          tint: .orange,
                                          detail: error.localized(localizer))
            }
            return StatusPresentation(text: localizer.t("Needs attention"),
                                      symbol: "exclamationmark.triangle.fill",
                                      tint: .orange,
                                      detail: error.localized(localizer))
        }

        if let localError {
            switch localError {
            case .syncFolderMissing:
                return StatusPresentation(text: localizer.t("Save folder missing"),
                                          symbol: "folder.badge.questionmark",
                                          tint: .orange,
                                          detail: localizer.t("Syncing will create it inside the authorised folder and restore the remote backup."))
            case .accessRootMissing:
                return StatusPresentation(text: localizer.t("Authorised folder missing"),
                                          symbol: "folder.badge.minus",
                                          tint: .red,
                                          detail: localError.localized(localizer))
            default:
                return StatusPresentation(text: localizer.t("Folder access lost"),
                                          symbol: "folder.badge.questionmark",
                                          tint: .red,
                                          detail: localError.localized(localizer))
            }
        }
        if !localReadable {
            return StatusPresentation(text: localizer.t("Folder access lost"),
                                      symbol: "folder.badge.questionmark",
                                      tint: .red,
                                      detail: localizer.t("The selected folder is no longer available. Pick it again in the game settings."))
        }

        switch decision {
        case .blocked:
            return StatusPresentation(text: localizer.t("Needs attention"),
                                      symbol: "exclamationmark.triangle.fill",
                                      tint: .orange,
                                      detail: nil)
        case .conflict:
            return StatusPresentation(text: localizer.t("Needs attention"),
                                      symbol: "arrow.left.arrow.right",
                                      tint: .orange,
                                      detail: localizer.t("Both versions have the same timestamp but different content."))
        case .upToDate:
            if remote == nil && local?.isEmpty == true {
                return StatusPresentation(text: localizer.t("No remote save yet"),
                                          symbol: "arrow.triangle.branch",
                                          tint: .secondary,
                                          detail: nil)
            }
            return StatusPresentation(text: localizer.t("Up to date"),
                                      symbol: "checkmark.circle.fill",
                                      tint: .green,
                                      detail: nil)
        case .upload(let reason):
            switch reason {
            case .firstSyncLocalOnly:
                return StatusPresentation(text: localizer.t("Only on this device"),
                                          symbol: "arrow.up.circle.fill",
                                          tint: .blue,
                                          detail: nil)
            case .cloudEmpty:
                return StatusPresentation(text: localizer.t("Local is newer"),
                                          symbol: "arrow.up.circle.fill",
                                          tint: .blue,
                                          detail: localizer.t("The remote backup is empty. Uploading will replace it with your local saves."))
            default:
                return StatusPresentation(text: localizer.t("Local is newer"),
                                          symbol: "arrow.up.circle.fill",
                                          tint: .blue,
                                          detail: nil)
            }
        case .download(let reason):
            switch reason {
            case .firstSyncCloudOnly:
                return StatusPresentation(text: localizer.t("Only on GitHub"),
                                          symbol: "arrow.down.circle",
                                          tint: .indigo,
                                          detail: nil)
            case .localEmpty:
                return StatusPresentation(text: localizer.t("Remote is newer"),
                                          symbol: "arrow.down.circle.fill",
                                          tint: .indigo,
                                          detail: localizer.t("The local folder is empty. Restoring will fill it with the remote backup."))
            default:
                return StatusPresentation(text: localizer.t("Remote is newer"),
                                          symbol: "arrow.down.circle.fill",
                                          tint: .indigo,
                                          detail: nil)
            }
        }
    }
}

struct StatusPill: View {
    var presentation: StatusPresentation

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: presentation.symbol)
                .font(.caption2.weight(.semibold))
            Text(presentation.text)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(presentation.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(presentation.tint.opacity(0.12), in: Capsule())
    }
}

struct InfoRow: View {
    var label: String
    var value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(mono ? .callout.monospaced() : .callout)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

struct PrimaryActionButton: View {
    var title: String
    var symbol: String
    var prominent: Bool
    var action: () -> Void

    var body: some View {
        if prominent {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

struct EmptyGamesView: View {
    var localizer: Localizer
    var add: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(localizer.t("Add Game"))
                .font(.headline)
            Text(localizer.t("Add a game, pick its save folder on this device, and keep a full copy in your private GitHub repository."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(action: add) {
                Label(localizer.t("Add Game"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
    }
}

struct ToastView: View {
    var item: AppModel.ToastItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol)
                .foregroundStyle(.white)
            Text(item.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.black.opacity(0.82), in: Capsule())
        .shadow(radius: 12, y: 4)
    }
}

enum PlatformStyle {
    static var horizontalPadding: CGFloat {
        #if os(macOS)
        return 20
        #else
        return 16
        #endif
    }
}
