import SwiftUI

#if os(iOS)
import UIKit

/// Wraps `UIDocumentPickerViewController` in folder mode. The picker is the only supported way
/// for an iOS app to reach a folder inside another app's Documents directory or iCloud Drive.
struct FolderPickerSheet: UIViewControllerRepresentable {
    var directoryURL: URL? = nil
    var onPick: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.directoryURL = directoryURL
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (URL) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            // Hold the scope while the caller creates its bookmark; the caller re-acquires it
            // later for every operation.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

#elseif os(macOS)
import AppKit

enum FolderPickerSheet {
    @MainActor
    static func chooseDirectory(directoryURL: URL? = nil,
                                localizer: Localizer = Localizer(language: .systemDefault),
                                completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = directoryURL
        panel.prompt = localizer.t("Choose This Folder")
        panel.message = localizer.t("Choose a folder")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                completion(nil)
                return
            }
            let scope = ScopedAccess(url: url)
            defer { scope.stop() }
            completion(url)
        }
        // Attach to the frontmost sheet (the editor/browser), not the covered main window.
        // An asynchronous panel keeps SwiftUI tasks and nested sheet dismissal responsive.
        var parent = NSApp.keyWindow
        while let sheet = parent?.attachedSheet { parent = sheet }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
#endif

/// Cross-platform "choose a folder" button. iOS presents the document picker as a sheet,
/// macOS opens an `NSOpenPanel`.
struct FolderPickerButton: View {
    @Environment(AppModel.self) private var model
    var title: String
    var onPick: (URL) -> Void

    @State private var showingPicker = false

    var body: some View {
        Button {
            #if os(macOS)
            FolderPickerSheet.chooseDirectory(localizer: model.l) { url in
                if let url { onPick(url) }
            }
            #else
            showingPicker = true
            #endif
        } label: {
            Label(title, systemImage: "folder")
        }
        #if os(iOS)
        .sheet(isPresented: $showingPicker) {
            FolderPickerSheet(onPick: { url in
                showingPicker = false
                onPick(url)
            }, onCancel: {
                showingPicker = false
            })
            .ignoresSafeArea()
        }
        #endif
    }
}
