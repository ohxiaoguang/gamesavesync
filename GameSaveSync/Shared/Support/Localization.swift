import Foundation

/// Supported UI languages. `.system` follows the device language.
public enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system
    case english
    case chinese

    public var resolved: ResolvedLanguage {
        switch self {
        case .english: return .english
        case .chinese: return .chinese
        case .system:
            return ResolvedLanguage.systemDefault
        }
    }
}

public enum ResolvedLanguage: String, Codable, Sendable {
    case english
    case chinese

    public var localeIdentifier: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// Chinese when the preferred system language starts with "zh", English otherwise.
    public static var systemDefault: ResolvedLanguage {
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return .chinese }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }
}

/// Lightweight runtime localization.
///
/// Keys are the English strings themselves, which keeps call sites readable and makes a
/// missing translation degrade to English instead of showing a raw identifier.
public struct Localizer: Sendable {
    public let language: ResolvedLanguage

    public init(language: ResolvedLanguage) {
        self.language = language
    }

    public func t(_ key: String) -> String {
        guard language == .chinese else { return key }
        return Self.chinese[key] ?? key
    }

    /// Localized `String(format:)` variant.
    public func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    public var locale: Locale { language.locale }

    /// "1 file" / "3 files" / "3 个文件"
    public func files(_ count: Int) -> String {
        if language == .chinese { return "\(count) 个文件" }
        return count == 1 ? "1 file" : "\(count) files"
    }

    static let chinese: [String: String] = [
        // MARK: General
        "GameSaveSync": "GameSaveSync",
        "Games": "游戏",
        "Settings": "设置",
        "Add Game": "添加游戏",
        "Edit Game": "编辑游戏",
        "Done": "完成",
        "Cancel": "取消",
        "Save": "保存",
        "Delete": "删除",
        "Delete Game": "删除游戏",
        "Delete Configuration": "删除配置",
        "Close": "关闭",
        "OK": "好",
        "Retry": "重试",
        "Refresh": "刷新",
        "Continue": "继续",
        "Back": "返回",
        "Details": "详情",
        "About": "关于",
        "Warning": "警告",
        "Error": "错误",
        "Note": "提示",
        "Unknown": "未知",
        "Never": "从未",
        "None": "无",
        "Version": "版本",
        "Histories": "历史记录",

        // MARK: Game fields
        "Name": "名称",
        "Game Name": "游戏名称",
        "Game Name (e.g. Darkest Dungeon)": "游戏名称（例如 暗黑地牢）",
        "Game ID": "游戏 ID",
        "Used to match backups between devices. Letters, numbers, dots and dashes.": "用于在不同设备之间匹配备份。支持字母、数字、点和短横线。",
        "Local Save Folder": "本地存档文件夹",
        "Choose Folder…": "选择文件夹…",
        "Change Folder": "更改文件夹",
        "Not selected": "未选择",
        "Folder access lost": "文件夹授权已失效",
        "Reselect Folder": "重新选择文件夹",
        "This folder can no longer be opened. Pick it again to restore access.": "无法再访问该文件夹，请重新选择以恢复授权。",
        "A game with this ID already exists.": "该游戏 ID 已存在。",
        "Enter a game name.": "请输入游戏名称。",
        "Choose a local save folder.": "请选择本地存档文件夹。",

        // MARK: Status
        "Local": "本地",
        "Cloud": "云端",
        "Local: %@": "本地：%@",
        "Cloud: %@": "云端：%@",
        "Local is newer": "本地版本较新",
        "Cloud is newer": "云端版本较新",
        "Up to date": "已是最新",
        "Needs attention": "需要确认",
        "Not synced yet": "尚未同步",
        "Only on this device": "仅本机有存档",
        "Only in the cloud": "仅云端有存档",
        "Cloud backup missing": "云端备份不存在",
        "Cloud backup incomplete": "云端备份不完整",
        "Checking…": "检查中…",
        "Local save folder is empty": "本地存档为空",
        "Synced %@": "同步于 %@",
        "Last sync: %@": "最近同步：%@",

        // MARK: Actions
        "Sync": "同步",
        "Upload": "上传",
        "Restore": "恢复",
        "Upload Local Save": "上传本地存档",
        "Restore Cloud Save": "恢复云端存档",
        "Upload (Overwrite Cloud)": "上传（覆盖云端）",
        "Restore (Overwrite Local)": "恢复（覆盖本地）",
        "Restore This Version": "恢复此版本",
        "History": "历史",
        "Cloud History": "云端历史",
        "Local Backups": "本地备份",
        "No history yet": "暂无历史记录",
        "No local backups yet": "暂无本地备份",
        "Created %@": "创建于 %@",
        "Files": "文件",
        "Size": "大小",
        "Source": "来源",
        "Backup": "备份",

        // MARK: Progress phases
        "Scanning local saves…": "正在扫描本地存档…",
        "Computing checksums…": "正在计算校验值…",
        "Creating archive…": "正在打包…",
        "Verifying archive…": "正在校验备份…",
        "Writing to iCloud Drive…": "正在写入 iCloud Drive…",
        "Waiting for iCloud upload…": "正在等待 iCloud 上传…",
        "Downloading cloud backup…": "正在下载云端备份…",
        "Waiting for iCloud download…": "正在等待 iCloud 下载…",
        "Extracting archive…": "正在解压…",
        "Verifying restored files…": "正在校验恢复的文件…",
        "Backing up current saves…": "正在备份当前存档…",
        "Replacing local saves…": "正在替换本地存档…",
        "Cleaning up…": "正在清理…",
        "Reading cloud manifest…": "正在读取云端清单…",

        // MARK: Outcomes
        "Uploaded": "已上传",
        "Restored": "已恢复",
        "Already up to date": "已是最新",
        "Uploaded (waiting for iCloud)": "已写入 iCloud Drive，等待上传",
        "Restored from history": "已从历史版本恢复",
        "Sync complete": "同步完成",
        "Sync cancelled": "已取消同步",
        "Uploaded %@ files (%@)": "已上传 %@ 个文件（%@）",
        "Restored %@ files (%@)": "已恢复 %@ 个文件（%@）",
        "No changes were made.": "未做任何更改。",

        // MARK: Confirmations
        "Close the game before syncing. GameSaveSync backs up your current saves, then replaces the folder you selected.": "同步前请关闭游戏。GameSaveSync 会先备份当前存档，再替换你选择的文件夹。",
        "Both versions have the same timestamp but different content.": "两个版本的时间相同，但内容不同。",
        "Choose which version to keep. The other side will be overwritten.": "请选择要保留的版本，另一侧将被覆盖。",
        "Use Local Version": "使用本地版本",
        "Use Cloud Version": "使用云端版本",
        "Local version": "本地版本",
        "Cloud version": "云端版本",
        "This will replace the cloud backup with your local saves.": "这将用本地存档覆盖云端备份。",
        "This will replace your local saves with the cloud backup.": "这将用云端备份覆盖本地存档。",
        "An automatic backup of the version being replaced is created first.": "被覆盖的版本会先自动备份。",
        "Upload now?": "现在上传？",
        "Restore now?": "现在恢复？",
        "The local folder is empty. Restoring will fill it with the cloud backup.": "本地文件夹为空，恢复将写入云端备份。",
        "The cloud backup is empty. Uploading will replace it with your local saves.": "云端备份为空，上传将用本地存档替换它。",
        "The timestamps are far apart. Check that the clock on both devices is correct.": "两端时间差距较大，请确认设备时间是否准确。",
        "Delete this game configuration?": "删除这个游戏配置？",
        "The save files themselves are not deleted. Only the configuration is removed from this device.": "不会删除真实存档文件，只会在本设备移除该配置。",

        // MARK: Settings
        "iCloud Drive Folder": "iCloud Drive 根目录",
        "The folder where all game backups are stored.": "所有游戏备份保存的位置。",
        "Not configured": "未配置",
        "Configured": "已配置",
        "Configure iCloud Drive first": "请先配置 iCloud Drive",
        "iCloud Drive is not set up yet. Choose a folder inside iCloud Drive, for example iCloud Drive/GameSaveSync.": "尚未设置 iCloud Drive。请选择一个 iCloud Drive 内的文件夹，例如 iCloud Drive/GameSaveSync。",
        "History Versions": "历史版本数量",
        "Keep last %d versions": "保留最近 %d 个版本",
        "Language": "语言",
        "System Default": "跟随系统",
        "English": "English",
        "中文": "中文",
        "Device Name": "设备名称",
        "Used in backup manifests to show where a backup came from.": "记录在备份清单中，用于显示备份来源设备。",
        "About GameSaveSync": "关于 GameSaveSync",
        "Version %@ (%@)": "版本 %@（%@）",
        "GameSaveSync keeps a complete copy of each game's save folder in iCloud Drive. Everything runs on device: no account, no server, no background sync.": "GameSaveSync 会把每个游戏的存档文件夹完整复制到 iCloud Drive。全部在本地完成：不需要账号、服务器或后台同步。",
        "Open iCloud Drive folder": "打开 iCloud Drive 目录",
        "Storage location": "存储位置",
        "Waiting for iCloud sync": "等待 iCloud 同步",
        "Uploaded to iCloud": "已上传至 iCloud",

        // MARK: Recovery
        "Interrupted operation found": "发现中断的操作",
        "A previous replacement did not finish. The old saves were kept here.": "上一次替换未完成，旧存档保留在以下位置。",
        "Recover Old Saves": "恢复旧存档",
        "Discard": "丢弃",
        "Recovered previous saves.": "已恢复之前的存档。",

        // MARK: Errors
        "The selected folder is no longer available. Pick it again in the game settings.": "所选文件夹已不可用，请在游戏设置中重新选择。",
        "The iCloud Drive folder is not configured.": "尚未配置 iCloud Drive 根目录。",
        "No cloud backup exists for this game yet.": "该游戏还没有云端备份。",
        "The cloud backup is incomplete. It may still be uploading from another device.": "云端备份不完整，可能仍在从其他设备上传。",
        "The cloud backup has not been downloaded yet. Connect to the internet and try again.": "云端备份尚未下载完成，请联网后重试。",
        "The cloud backup failed verification and was not applied.": "云端备份校验失败，未做任何更改。",
        "The archive is damaged or was modified after it was created.": "备份文件已损坏或创建后被修改。",
        "The backup contains an unsafe file path and was rejected.": "备份包含不安全的文件路径，已拒绝处理。",
        "The backup is too large to process on this device.": "备份过大，无法在此设备处理。",
        "Could not create the safety backup, so nothing was changed.": "无法创建安全备份，因此未做任何更改。",
        "Replacing the folder failed. Your previous saves were restored.": "替换文件夹失败，已恢复之前的存档。",
        "Replacing the folder failed and the automatic rollback also failed. Your saves are kept at the path below.": "替换失败且自动回滚也失败，存档保留在下面显示的路径中。",
        "This device is offline or iCloud is unavailable.": "设备离线或 iCloud 不可用。",
        "The iCloud backup is still being written and cannot be used yet.": "云端备份仍在写入中，暂时无法使用。",
        "The folder could not be created.": "无法创建文件夹。",
        "No game backup was found for this ID.": "未找到该 ID 的云端备份。",
        "The cloud folder is read-only.": "云端文件夹不可写。",
        "Something went wrong.": "出现错误。",
        "Open the Files app and go to iCloud Drive.": "打开「文件」App，进入 iCloud Drive。",
        "Create a folder named GameSaveSync (or pick any folder you like).": "新建一个名为 GameSaveSync 的文件夹（也可以选择任意文件夹）。",
        "Come back here and select that folder.": "回到这里选择该文件夹。",
        "Everything runs on this device. Saves are copied to the iCloud Drive folder you picked.": "所有处理都在本设备完成，存档会复制到你选择的 iCloud Drive 文件夹。",
        "Add a game, pick its save folder on this device, and keep a full copy in iCloud Drive.": "添加游戏，选择它在当前设备上的存档文件夹，并在 iCloud Drive 中保留完整副本。",
        "Pick the folder that holds this game's saves on this device. It can be a different path on every device.": "选择该游戏在当前设备上的存档文件夹。不同设备可以使用完全不同的路径。",
        "If the cloud already has a backup for this ID, it will be linked automatically.": "如果云端已存在该 ID 的备份，将自动关联。",
        "The local save folder is empty, so nothing was uploaded.": "本地存档文件夹为空，未上传任何内容。",
        "Status": "状态",
        "Actions": "操作",
        "Last Sync": "最近同步",
        "Choose a folder inside iCloud Drive, for example iCloud Drive/GameSaveSync.": "请选择一个 iCloud Drive 内的文件夹，例如 iCloud Drive/GameSaveSync。",
        "On this device only — not synced": "仅保存在本机（不同步）",
        "This folder is not in iCloud Drive": "这个文件夹不在 iCloud Drive 中",
        "Use Anyway": "仍然使用",
        "Choose Again": "重新选择",
        "Backups stay on this device and will not appear on your other devices. Choose a folder inside iCloud Drive to sync between iPhone, iPad and Mac.": "备份只会保留在这台设备上，不会出现在你的其他设备上。若要在 iPhone、iPad 和 Mac 之间同步，请选择 iCloud Drive 内的文件夹。",
        "Backups are written into this folder. Choose a different one at any time.": "备份会写入这个文件夹，你可以随时更换。",
        "Authorised Folder": "授权文件夹",
        "Recommend the game's Documents folder": "建议选择游戏的 Documents 目录",
        "Recommended: the game's Documents folder. GameSaveSync gets one grant here and never touches anything outside the sync folder.": "建议选择游戏的 Documents 目录。GameSaveSync 只在这里获取一次授权，不会读写同步文件夹以外的内容。",
        "Sync Folder": "实际同步文件夹",
        "Only this folder and its contents are synced. Other folders and files in the authorised folder are never uploaded or overwritten.": "仅同步此文件夹及其内容，授权文件夹里的其他文件不会上传也不会被覆盖。",
        "Only this folder and its contents are synced. The rest of the authorised folder is left alone.": "仅同步此文件夹及其内容，授权文件夹里的其他内容不受影响。",
        "The whole authorised folder will be synced.": "将同步整个授权文件夹。",
        "Choosing this folder syncs everything inside the authorised folder.": "选择此文件夹会同步授权文件夹内的全部内容。",
        "Choose This Folder": "选择此文件夹",
        "Subfolders": "子文件夹",
        "There are no subfolders here.": "这里没有子文件夹。",
        "You can choose this folder itself.": "可以直接选择这个文件夹。",
        "Reading…": "正在读取…",
        "Could not read this folder.": "无法读取这个文件夹。",
        "Reading this folder timed out.": "读取这个文件夹超时了。",
        "iCloud or the file provider did not answer. You can try again, or choose the folder that is already authorised.": "iCloud 或文件提供者没有响应。可以重试，或直接选择已授权的这个文件夹。",
        "Try Again": "重试",
        "Choose with Finder…": "用访达选择…",
        "Choose a folder": "选择文件夹",
        "Parent Folder": "上一级",
        "Could not select this folder.": "无法选择此文件夹。",
        "Choose with the Files app…": "用「文件」App 选择…",
        "That folder is outside the authorised folder.": "这个文件夹不在授权范围内。",
        "Pick a folder inside the authorised folder.": "请选择授权文件夹内部的一个子文件夹。",
        "Choose…": "选择",
        "Change": "更换",
        "Choose an authorised folder first.": "请先选择授权文件夹。",
        "This game was added before authorised folders existed, so its grant covers the save folder itself. Choose the game's Documents folder to sync a subfolder.": "这个游戏是在「授权文件夹」功能之前添加的，授权范围就是存档文件夹本身。若只同步其中某个子文件夹，请改为选择游戏的 Documents 目录。",
        "This game uses an older folder grant. Choose the game's Documents folder to sync a subfolder.": "此游戏使用的是旧版授权范围。若要只同步某个子文件夹，请改为选择游戏的 Documents 目录。",
        "Save folder missing": "存档目录不存在",
        "The save folder does not exist yet.": "存档目录不存在。",
        "Authorised folder missing": "授权文件夹不存在",
        "The authorised folder no longer exists. Choose the folder again.": "授权文件夹已不存在，请重新选择。",
        "GameSaveSync lost access to the authorised folder. Choose the folder again.": "GameSaveSync 已失去授权文件夹的访问权限，请重新选择。",
        "Save folder outside the authorised folder": "同步目录超出授权范围",
        "The save folder is outside the authorised folder.": "同步目录不在授权文件夹内。",
        "Syncing will create it inside the authorised folder and restore the cloud backup.": "同步时会在授权文件夹内创建它，并恢复云端存档。",
        "OK, understood": "我知道了",
    ]
}
