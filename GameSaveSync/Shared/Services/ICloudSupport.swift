import Foundation

/// Queries the iCloud Drive state of a URL.
///
/// Writing a file into an iCloud Drive folder only means the local File Provider copy accepted
/// it. These helpers distinguish "written locally", "downloaded", and "confirmed uploaded" so the
/// UI never claims an upload that has not happened.
public enum ICloudSupport {
    public enum DownloadState: String, Sendable {
        case notICloud
        case current
        case needsDownload
        case unknown
    }

    public enum UploadState: Sendable {
        case uploaded
        case pending
        /// The URL is not managed by iCloud (e.g. a plain local folder).
        case notICloud
        case unknown
    }

    public static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// True when the folder is stored in iCloud Drive and therefore visible on the user's other
    /// devices. Falls back to the well-known container path because `isUbiquitousItem` can read
    /// as `false` for a folder that has never been downloaded or synced on this device.
    public static func isInICloudDrive(_ url: URL) -> Bool {
        if isUbiquitous(url) { return true }
        let path = url.standardizedFileURL.path
        return path.contains("/com~apple~CloudDocs/") || path.hasSuffix("/com~apple~CloudDocs")
    }

    public static func downloadState(of url: URL) -> DownloadState {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]) else {
            return .unknown
        }
        guard values.isUbiquitousItem == true else { return .notICloud }
        switch values.ubiquitousItemDownloadingStatus {
        case .some(.current): return .current
        case .some(.downloaded): return .current
        case .some(.notDownloaded): return .needsDownload
        default: return .unknown
        }
    }

    /// Blocks until the item is materialised locally, requesting a download when needed.
    public static func ensureDownloaded(_ url: URL, timeout: TimeInterval = 120) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw SyncError.cloudNotDownloaded
        }
        switch downloadState(of: url) {
        case .notICloud, .current:
            return
        case .unknown:
            return
        case .needsDownload:
            break
        }

        do {
            try fm.startDownloadingUbiquitousItem(at: url)
        } catch {
            throw SyncError.cloudNotDownloaded
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch downloadState(of: url) {
            case .current, .notICloud:
                return
            case .needsDownload, .unknown:
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        throw SyncError.cloudNotDownloaded
    }

    /// Best-effort check that iCloud accepted the file for upload.
    /// Returns `.pending` when the item is still uploading after `timeout`, and `.notICloud`
    /// immediately for folders that are not managed by iCloud at all.
    public static func awaitUpload(_ urls: [URL], timeout: TimeInterval = 25) -> UploadState {
        var ubiquitous: [URL] = []
        for url in urls where isUbiquitous(url) {
            ubiquitous.append(url)
        }
        guard !ubiquitous.isEmpty else { return .notICloud }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var allUploaded = true
            var known = false
            for url in ubiquitous {
                guard let values = try? url.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]) else {
                    continue
                }
                known = true
                if values.ubiquitousItemIsUploaded != true {
                    allUploaded = false
                }
            }
            if known && allUploaded { return .uploaded }
            if Date() >= deadline { return .pending }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }
}
