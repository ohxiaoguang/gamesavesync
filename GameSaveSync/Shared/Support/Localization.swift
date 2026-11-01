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
        "Load more": "加载更多",

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
        "Remote": "远端",
        "Local: %@": "本地：%@",
        "Remote: %@": "远端：%@",
        "Local is newer": "本地版本较新",
        "Remote is newer": "远端版本较新",
        "Up to date": "已是最新",
        "Needs attention": "需要确认",
        "Not synced yet": "尚未同步",
        "Only on this device": "仅本机有存档",
        "Only on GitHub": "仅 GitHub 上有存档",
        "No remote save yet": "远端还没有存档",
        "Remote save incomplete": "远端存档不完整",
        "Remote version changed": "远端版本已变化",
        "Checking…": "检查中…",
        "Local save folder is empty": "本地存档为空",
        "Synced %@": "同步于 %@",
        "Last sync: %@": "最近同步：%@",
        "Offline": "网络不可用",
        "Connection timed out": "连接超时",
        "Token rejected": "访问令牌无效",
        "Missing permission": "权限不足",
        "Rate limited": "请求过于频繁",
        "Repository not found": "仓库不存在",
        "Repository is not private": "仓库不是私有仓库",
        "Branch not found": "分支不存在",
        "Connect a GitHub repository": "请配置 GitHub 仓库",

        // MARK: Actions
        "Sync": "同步",
        "Upload": "上传",
        "Restore": "恢复",
        "Upload Local Save": "上传本地存档",
        "Restore Cloud Save": "恢复远端存档",
        "Upload (Overwrite Remote)": "上传（覆盖远端）",
        "Restore (Overwrite Local)": "恢复（覆盖本地）",
        "Upload (Overwrite Cloud)": "上传（覆盖远端）",
        "Restore This Version": "恢复此版本",
        "History": "历史",
        "Version History": "历史版本",
        "Cloud History": "历史版本",
        "Local Backups": "本地备份",
        "No history yet": "暂无历史记录",
        "No local backups yet": "暂无本地备份",
        "Created %@": "创建于 %@",
        "Files": "文件",
        "Size": "大小",
        "Source": "来源",
        "Backup": "备份",

        // MARK: Progress phases
        "Connecting to GitHub…": "正在连接 GitHub…",
        "Reading the remote version…": "正在读取远端版本…",
        "Scanning local saves…": "正在扫描本地存档…",
        "Computing checksums…": "正在计算校验值…",
        "Creating archive…": "正在压缩存档…",
        "Verifying archive…": "正在校验备份…",
        "Uploading to GitHub…": "正在上传到 GitHub…",
        "Creating commit…": "正在创建提交…",
        "Downloading save…": "正在下载存档…",
        "Extracting archive…": "正在解压…",
        "Verifying restored files…": "正在校验恢复的文件…",
        "Backing up current saves…": "正在备份当前存档…",
        "Replacing local saves…": "正在替换本地存档…",
        "Cleaning up…": "正在清理…",

        // MARK: Outcomes
        "Uploaded": "已上传",
        "Restored": "已恢复",
        "Already up to date": "已是最新",
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
        "Use Remote Version": "使用远端版本",
        "Use Cloud Version": "使用远端版本",
        "Local version": "本地版本",
        "Remote version": "远端版本",
        "Cloud version": "远端版本",
        "This will replace the remote backup with your local saves.": "这将用本地存档覆盖远端备份。",
        "This will replace your local saves with the remote backup.": "这将用远端备份覆盖本地存档。",
        "This will replace the cloud backup with your local saves.": "这将用本地存档覆盖远端备份。",
        "This will replace your local saves with the cloud backup.": "这将用远端备份覆盖本地存档。",
        "An automatic backup of the version being replaced is created first.": "被覆盖的版本会先自动备份。",
        "Upload to GitHub?": "上传到 GitHub？",
        "The whole save folder is uploaded as this game's first version on GitHub.": "整个存档文件夹会作为这个游戏在 GitHub 上的第一个版本上传。",
        "This save is larger than 50 MiB (%@). Uploading takes longer and the GitHub repository grows with every version.": "存档超过 50 MiB（%@），上传会更久，GitHub 仓库体积也会随每次版本增长更快。",
        "Upload now?": "现在上传？",
        "Restore now?": "现在恢复？",
        "The local folder is empty. Restoring will fill it with the remote backup.": "本地文件夹为空，恢复将写入远端备份。",
        "The remote backup is empty. Uploading will replace it with your local saves.": "远端备份为空，上传将用本地存档替换它。",
        "The timestamps are far apart. Check that the clock on both devices is correct.": "两端时间差距较大，请确认设备时间是否准确。",
        "Delete this game configuration?": "删除这个游戏配置？",
        "The save files themselves are not deleted. Only the configuration is removed from this device.": "不会删除真实存档文件，只会在本设备移除该配置。",

        // MARK: Settings
        "GitHub Repository": "GitHub 仓库",
        "Repository Owner": "仓库所有者",
        "Repository": "仓库",
        "If GitHub already has a backup for this ID, it will be linked automatically.": "如果 GitHub 上已经有这个 ID 的备份，会自动关联。",
        "Repository Name": "仓库名称",
        "private save repository": "私有存档仓库",
        "Branch": "分支",
        "Use a private repository you created for game saves. GameSaveSync writes only to games/<game id>/ and never changes repository settings.": "请使用你为游戏存档单独创建的私有仓库。GameSaveSync 只写入 games/<游戏 ID>/，不会修改仓库设置。",
        "Access Token": "访问令牌",
        "Token saved — enter a new one to replace it": "令牌已保存，输入新的令牌可替换",
        "Save Token": "保存令牌",
        "Remove Token": "删除令牌",
        "Token saved in the Keychain": "令牌已存入钥匙串",
        "Token stored in the Keychain": "令牌已保存在钥匙串",
        "No token stored": "尚未保存令牌",
        "Fine-grained token with Contents: Read and write on this repository. It is stored in the Keychain, never in settings.json or the logs.": "使用 Fine-grained 令牌，只需对该仓库的 Contents 具备 Read and write 权限。令牌保存在钥匙串中，不会写入 settings.json 或日志。",
        "Connection": "连接",
        "Test Connection": "测试连接",
        "Testing…": "正在测试…",
        "Connected": "已连接",
        "Not connected": "未连接",
        "Permissions": "权限",
        "Read and write": "可读取 / 可写入",
        "Read only": "只读",
        "No access": "无访问权限",
        "Private": "Private",
        "Public": "Public",
        "empty (set up on first upload)": "空仓库（首次上传自动初始化）",
        "readable": "可访问",
        "The test checks that the repository exists, belongs to the owner, is private, and that the token may read and write the branch.": "测试会确认仓库存在、属于指定所有者、是私有仓库，并且令牌可以读写目标分支。",
        "The token can read this repository but cannot write to it. It needs Contents: Read and write.": "该令牌可以读取仓库，但无法写入。需要 Contents: Read and write 权限。",
        "How many safety copies of a save folder are kept on this device. GitHub keeps every uploaded version in its own commit.": "本机为每个存档文件夹保留多少份安全备份。GitHub 上每个上传版本都会保留为一个独立的提交。",
        "Not configured": "未配置",
        "Configured": "已配置",
        "Language": "语言",
        "System Default": "跟随系统",
        "English": "English",
        "中文": "中文",
        "Device Name": "设备名称",
        "Recorded in each manifest so you can see which device uploaded a version.": "记录在每次备份的清单里，用于显示版本来自哪台设备。",
        "About GameSaveSync": "关于 GameSaveSync",
        "Version %@ (%@)": "版本 %@（%@）",
        "GameSaveSync archives each game's save folder and keeps it in your private GitHub repository. Saves are read only on this device and only when you start a sync.": "GameSaveSync 会把每个游戏的存档文件夹打包，存进你自己的 GitHub 私有仓库。存档只在本机读取，而且只在你开始同步时读取。",

        // MARK: Home screen
        "Connect your GitHub repository": "连接你的 GitHub 仓库",
        "Add the owner, repository name and an access token in Settings to sync between devices.": "在设置里填写所有者、仓库名称和访问令牌，即可在多台设备之间同步。",
        "Save folders stay on this device. Each game's folder is uploaded to your private GitHub repository.": "存档文件夹保留在本机，每个游戏的文件夹会上传到你的 GitHub 私有仓库。",
        "Add a game, pick its save folder on this device, and keep a full copy in your private GitHub repository.": "添加游戏，选择它在当前设备上的存档文件夹，并把完整副本保存到你的 GitHub 私有仓库。",

        // MARK: Recovery
        "Interrupted operation found": "发现中断的操作",
        "A previous replacement did not finish. The old saves were kept here.": "上一次替换未完成，旧存档保留在以下位置。",
        "Recover Old Saves": "恢复旧存档",
        "Discard": "丢弃",
        "Recovered previous saves.": "已恢复之前的存档。",

        // MARK: Errors
        "The selected folder is no longer available. Pick it again in the game settings.": "所选文件夹已不可用，请在游戏设置中重新选择。",
        "No GitHub repository is configured yet. Add the owner, repository name and access token in Settings.": "尚未配置 GitHub 仓库。请在设置里填写仓库所有者、仓库名称和访问令牌。",
        "No save exists for this game on GitHub yet.": "该游戏在 GitHub 上还没有存档。",
        "The remote save is incomplete and cannot be used.": "远端存档不完整，无法使用。",
        "The remote save failed verification and was not applied.": "远端存档校验失败，未做任何更改。",
        "Another device changed this game on GitHub after the comparison started. Nothing was overwritten — sync again to compare the new version.": "在比较开始后，另一台设备已在 GitHub 上更新了该游戏。没有覆盖任何内容，请重新同步以比较新版本。",
        "The repository has no commits yet. The first upload sets it up automatically.": "仓库还没有任何提交，首次上传会自动初始化。",
        "GitHub rejected the access token. Check that it is correct and not expired.": "GitHub 拒绝了这个访问令牌，请确认令牌正确且未过期。",
        "The access token is not allowed to do this. It needs Contents: Read and write on this repository.": "该访问令牌没有此权限，需要对该仓库具备 Contents: Read and write。",
        "GitHub is rate limiting requests. Try again later.": "GitHub 请求频率受限，请稍后再试。",
        "Retry in %d seconds.": "约 %d 秒后可重试。",
        "The repository was not found. Check the owner and repository name, and that the token can access it.": "找不到该仓库，请检查所有者、仓库名称，以及令牌是否有访问权限。",
        "The requested item does not exist in the repository.": "仓库中不存在所请求的内容。",
        "This repository is not private. GameSaveSync only stores saves in a private repository.": "该仓库不是私有仓库。GameSaveSync 只使用私有仓库保存存档。",
        "The branch does not exist in the repository. Create it on GitHub, or enter an existing branch in Settings.": "仓库中不存在该分支。请在 GitHub 上创建该分支，或在设置里填写已有的分支名。",
        "GitHub rejected the request because the repository changed. Try again.": "由于仓库发生变化，GitHub 拒绝了本次请求，请重试。",
        "GitHub returned a server error. Try again later.": "GitHub 返回了服务器错误，请稍后再试。",
        "GitHub returned an unexpected response.": "GitHub 返回了无法识别的响应。",
        "The archive is larger than GitHub's 100 MiB file limit, so it was not uploaded.": "压缩包超过 GitHub 100 MiB 的单文件限制，因此没有上传。",
        "No network connection. Connect to the internet and try again.": "网络不可用，请连接网络后重试。",
        "The connection to GitHub timed out.": "连接 GitHub 超时。",
        "The operation was cancelled.": "操作已取消。",
        "The archive is damaged or was modified after it was created.": "备份文件已损坏或创建后被修改。",
        "The backup contains an unsafe file path and was rejected.": "备份包含不安全的文件路径，已拒绝处理。",
        "The backup is too large to process on this device.": "备份过大，无法在此设备处理。",
        "Could not create the safety backup, so nothing was changed.": "无法创建安全备份，因此未做任何更改。",
        "Replacing the folder failed. Your previous saves were restored.": "替换文件夹失败，已恢复之前的存档。",
        "Replacing the folder failed and the automatic rollback also failed. Your saves are kept at the path below.": "替换失败且自动回滚也失败，存档保留在下面显示的路径中。",
        "The folder could not be created.": "无法创建文件夹。",
        "The local save folder is empty, so nothing was uploaded.": "本地存档文件夹为空，未上传任何内容。",
        "Something went wrong.": "出现错误。",
        "Status": "状态",
        "Actions": "操作",
        "Last Sync": "最近同步",
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
        "The folder provider did not answer. You can try again, or choose the folder that is already authorised.": "文件提供者没有响应。可以重试，或直接选择已授权的这个文件夹。",
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
        "Syncing will create it inside the authorised folder and restore the remote backup.": "同步时会在授权文件夹内创建它，并恢复远端存档。",
        "OK, understood": "我知道了",
    ]
}
