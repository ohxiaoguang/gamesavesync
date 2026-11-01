# GameSaveSync

把 iPhone / iPad / Mac 上同一款游戏的存档文件夹，通过 iCloud Drive 手工同步的工具。

- 原生 Swift + SwiftUI，iOS / iPadOS / macOS 共用一套界面、数据模型和同步逻辑。
- 不接入游戏本体，不需要服务器，不需要登录，不需要后台常驻。
- 不申请 iCloud 容器、CloudKit 等付费开发者专属能力：所有云端文件都在用户自己选择的 iCloud Drive 文件夹里，通过系统文件选择器取得授权。
- 所有同步都由用户主动点击触发。

---

## 1. 功能

| 功能 | 说明 |
| --- | --- |
| 游戏管理 | 名称 + 唯一游戏 ID + 本机存档文件夹；新增 / 编辑 / 删除配置（默认不删真实存档） |
| 目录授权 | iOS 用系统文件选择器（`UIDocumentPickerViewController`），macOS 用 `NSOpenPanel`；保存 Security-scoped Bookmark，重启后恢复；失效时提示重新选择 |
| 云端目录 | 首次使用时选择 iCloud Drive 里的一个文件夹作为同步根目录，iOS / macOS 各选一次 |
| 同步 | 整文件夹覆盖 + 最新存档优先；本地较新→上传，云端较新→恢复，内容相同→不动，时间相同内容不同→用户选择 |
| 强制覆盖 | 「上传」强制用本地覆盖云端，「恢复」强制用云端覆盖本地，执行前明确提示 |
| 安全 | 覆盖前自动备份、最近 N 个云端历史版本、下载校验、解压校验、原子替换、失败回滚、中断恢复 |
| 历史 | 云端历史版本可查看并恢复；本地也保留最近 N 份覆盖前快照 |
| 界面 | 原生 SwiftUI，浅色/深色，中文/英文（可跟随系统或在设置里切换），iPhone / iPad / Mac |

---

## 2. 环境与本次验证

| 项目 | 值 |
| --- | --- |
| Xcode | 27.1 (17A9275) |
| Swift | 6.4（工程使用 Swift 5 语言模式 + `SWIFT_STRICT_CONCURRENCY=minimal`） |
| 部署目标 | iOS 17.0 / macOS 14.0 |
| 构建产物 | macOS 通用二进制（arm64 + x86_64，ad-hoc 签名 + App Sandbox）；iOS arm64 `.app` → 未签名 IPA |
| 单元测试 | 53 个，全部通过（macOS 逻辑测试） |
| UI 测试 | 6 个，全部通过（iPhone 15 Pro 模拟器 / iOS 18.0） |

---

## 3. 目录结构

```text
gamesavesync/
├── project.yml                     # XcodeGen 工程描述
├── GameSaveSync.xcodeproj          # 已生成的工程，可直接打开
├── GameSaveSync/
│   ├── Shared/
│   │   ├── Models/                 # Game / AppSettings / SaveSnapshot / CloudManifest / 同步模型
│   │   ├── Services/               # 目录授权、配置存储、扫描、云端读写、备份、iCloud 状态
│   │   ├── Sync/                   # 决策、同步引擎、目录替换、ZIP 读写
│   │   ├── Views/                  # 列表 / 详情 / 编辑器 / 设置 / 冲突 / 目录选择
│   │   ├── App/                    # AppModel（@Observable）+ 开发用示例数据
│   │   └── Support/                # 本地化、格式化、哈希、日志
│   ├── iOS/                        # iOS 入口 + Info.plist
│   ├── macOS/                      # macOS 入口 + Info.plist + entitlements
│   └── Resources/                  # Assets（App 图标、强调色）
├── GameSaveSyncTests/              # 单元测试
├── GameSaveSyncUITests/            # 界面与端到端流程测试
├── scripts/
│   ├── build.sh                    # 一键构建 macOS App + 未签名 IPA
│   └── make-icon.swift             # 生成 App 图标
└── dist/                           # 构建产物
```

核心模块职责：

- `GameStore`（`ConfigurationStore`）：`games.json` / `settings.json` 的读写。
- `DirectoryAccessManager`：Bookmark 创建/解析、Security Scope 生命周期。
- `CloudStorageManager`：`<root>/<gameId>/` 下的 manifest、latest.zip、history 读写与协调。
- `SaveScanner`：递归扫描、最新文件时间、SHA-256 内容指纹。
- `ArchiveManager`：整目录 ZIP 打包/解包 + 精确时间戳旁路文件。
- `SyncEngine` + `SyncDecisionMaker`：版本比较与执行。
- `BackupManager`：本地安全快照。
- `DirectoryReplacer`：目录内容原子替换与回滚。

---

## 4. 构建

需要 Xcode 15 以上（本工程用 Xcode 27.1 验证）。XcodeGen 只在修改 `project.yml` 后需要。

```bash
# 生成工程（可选，仓库里已有 GameSaveSync.xcodeproj）
xcodegen generate

# 一键构建 macOS App 与未签名 IPA，产物在 dist/
./scripts/build.sh
```

单独构建：

```bash
# macOS
xcodebuild -project GameSaveSync.xcodeproj -scheme GameSaveSync-macOS \
  -configuration Release -derivedDataPath build/mac build

# iOS 模拟器
xcodebuild -project GameSaveSync.xcodeproj -scheme GameSaveSync-iOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15 Pro' build

# iOS 真机（未签名，用于后续自行签名）
xcodebuild -project GameSaveSync.xcodeproj -scheme GameSaveSync-iOS \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-device CODE_SIGNING_ALLOWED=NO build
```

产物：

- `dist/GameSaveSync.app`：macOS 应用（ad-hoc 签名，已启用 App Sandbox）。
- `dist/GameSaveSync-unsigned.ipa`：iOS 未签名 IPA（`Payload/GameSaveSync.app`，arm64）。

### 4.1 用免费 Apple ID 安装到 iPhone / iPad

未签名 IPA 需要用自己的 Apple ID 重新签名，以下两种方式都不需要付费开发者账号：

**方式 A：Xcode（推荐，7 天有效期）**

1. 打开 `GameSaveSync.xcodeproj`，选中 `GameSaveSync-iOS` target → *Signing & Capabilities*。
2. 勾选 *Automatically manage signing*，Team 选择你的个人 Apple ID（Xcode → Settings → Accounts 里添加）。
3. 如提示 bundle id 冲突，把 `com.gamesavesync.app` 改成任意唯一值（例如 `com.yourname.gamesavesync`）。
4. 连接设备，选择该设备运行。首次运行需在 iPhone「设置 → 通用 → VPN与设备管理」中信任开发者证书。

**方式 B：Sideloadly / AltStore（用 dist 里的 IPA）**

1. 安装 [Sideloadly](https://sideloadly.io/) 或 AltStore。
2. 把 `dist/GameSaveSync-unsigned.ipa` 拖入，填写 Apple ID，开始签名安装。
3. 免费账号的签名 7 天后过期，重新签一次即可（配置文件和历史数据不会丢）。

> 免费账号的限制来自 Apple 本身：7 天有效期、最多 3 个 App、不能使用 iCloud 容器 / CloudKit / Push 等能力。本 App 不使用这些能力。

---

## 5. 使用流程

1. **配置 iCloud Drive 根目录**：首次启动会弹出设置页。在「文件」App 的 iCloud Drive 里建一个 `GameSaveSync` 文件夹（也可以直接选 iCloud Drive 根目录，App 会自动在里面建 `GameSaveSync/`），然后在选择器里选中它。iPhone / iPad 和 Mac 各选一次，指向同一个位置。
   - 系统文件选择器不限制位置，理论上「我的 iPhone」上的目录也能选。**但只有 iCloud Drive 里的文件夹会跨设备同步**；选中不在 iCloud Drive 的目录时 App 会弹窗确认，确认后设置页会标为「仅保存在本机（不同步）」。要做真正的多设备同步，请务必选 iCloud Drive 内的文件夹。
2. **添加游戏**：点右上角 `+`，填游戏名称，游戏 ID 会自动按名称生成（可改，注意两端必须一致），然后分两步选文件夹：
   - **授权文件夹**：建议选游戏自己的 `Documents` 目录（iOS 上是游戏在「我的 iPhone / iCloud Drive」里开放的目录；macOS 上可以是 `~/Library/Application Support/...` 之类的任意目录）。App 只对这一层申请一次授权并保存书签。
   - **同步文件夹**：在授权文件夹里逐级浏览，选真正要同步的子目录，例如 `saves`。界面会显示成 `Documents / saves`。也可以直接选授权文件夹本身，此时会提示「将同步整个授权文件夹」。
   - 只有「同步文件夹」里的内容会被上传、备份、覆盖；`cache`、`config.json` 等兄弟文件永远不参与。同步文件夹被游戏删掉后重建，只要相对路径没变，下次仍能直接用。
3. **同步**：主界面每行右侧的循环按钮，或进入详情页点「同步」。
4. **详情页**可以看本地/云端时间、文件数与大小、最近同步结果、云端历史、本地备份，以及强制「上传」「恢复」。
5. **删除配置**只删本机的游戏配置，不删真实存档，也不删云端备份。

主界面只显示状态（一行一个），具体时间和操作都在详情页，避免手机屏幕拥挤。

---

## 6. 云端数据结构

```text
<iCloud Drive>/GameSaveSync/
├── darkest-dungeon/
│   ├── manifest.json
│   ├── latest.zip
│   └── history/
│       ├── 20261031T121500Z-1a2b3c4d.zip
│       └── 20261031T121500Z-1a2b3c4d.json
├── fc-27/
└── mario-wonder/
```

`manifest.json` 关键字段：

```json
{
  "schema": 1,
  "gameId": "darkest-dungeon",
  "gameName": "Darkest Dungeon",
  "versionId": "20261031T121500Z-1a2b3c4d",
  "saveModifiedAt": "2026-10-31T12:09:31.512Z",   // 原始存档最新修改时间（判定依据）
  "backupCreatedAt": "2026-10-31T12:15:02.004Z",  // 备份生成时间（不参与判定）
  "sourceDevice": "zzg 的 iPhone",
  "contentHash": "9f2c…",                          // 存档内容 SHA-256
  "fileCount": 12,
  "totalBytes": 1048576,
  "archiveFileName": "latest.zip",
  "archiveBytes": 302144,
  "archiveSHA256": "1c7d…",
  "status": "complete",
  "iCloudUploaded": true
}
```

写入顺序：先写 `latest.zip`（临时文件 → 校验 → 替换），最后写 `manifest.json`。因此读到 manifest 就一定对应一个已完成的压缩包；`status` 不是 `complete` 时一律拒绝使用。

ZIP 内部额外带一个 `.gamesavesync-archive.json` 旁路文件，记录每个文件的精确修改时间（ZIP 的 DOS 时间只有 2 秒精度且无时区），解压后据此还原时间戳，然后删除该文件。

---

## 7. 同步判定规则

一次「同步」的实际决策（`SyncDecisionMaker`）：

| 情况 | 判定 | 动作 |
| --- | --- | --- |
| 本地有、云端无 | `upload(.firstSyncLocalOnly)` | 上传 |
| 云端有、本地无/本地空 | `download(.firstSyncCloudOnly / .localEmpty)` | 恢复 |
| 两端内容哈希相同 | `upToDate` | 不动（即使时间不同） |
| 本地最新存档时间 > 云端 | `upload(.localNewer)` | 上传 |
| 云端最新存档时间 > 本地 | `download(.cloudNewer)` | 恢复 |
| 时间差 ≤ 2 秒且哈希不同 | `conflict` | 弹出选择：本地 / 云端 / 取消 |
| 两端都有内容但本设备从未同步过 | 按时间给出方向 + **强制确认** | 确认后执行 |
| 两端时间差 > 180 天 | `clockSkew` | 提示时钟可能不准，确认后执行 |

判定依据只有两个：**存档文件的最新修改时间** 和 **内容 SHA-256**。ZIP 创建时间、备份生成时间、下载时间、解压时间都不参与比较。

边界处理：

- 空文件夹：没有文件时时间戳记为 `nil`，用哈希（空集合的哈希）和文件数判断，不会因为「空文件夹的修改时间很新」而误判。
- 时间戳精度：比较容差 2 秒，避免不同文件系统/复制工具截断时间造成假「更新」。
- 时间没变但内容变了：哈希不同 → 冲突或按时间走，不会被当作「已是最新」。
- 时间相同内容相同：直接「已是最新」。

---

## 8. 安全设计

**覆盖前**

- 恢复前先把当前本地存档完整复制到 App 容器的 `Backups/<gameId>/<时间>-<随机>/Payload`，并重新扫描校验哈希一致；校验不一致（例如拷贝过程中游戏还在写盘）就中止，什么都不改。
- 云端压缩包先确认已下载完成（`ubiquitousItemDownloadingStatus`），再校验字节数与 SHA-256，再解压，再逐文件 CRC 校验，最后重新计算解压目录的内容哈希与 manifest 对比；任一步失败都不触碰本地存档。

**覆盖中**

- 新内容先解压到**目标文件夹内部**的 `.gamesavesync-stage-<uuid>/`。这样不需要父目录写权限（iOS 的授权只覆盖所选文件夹及其子项），也不跨卷。
- 替换时把旧文件移到 `.gamesavesync-previous-<uuid>/`，再把新文件移入；全部成功才删除旧目录。任何一步失败都按相反顺序移回，返回「已回滚」或「回滚失败，文件仍保留在 xxx」。

**覆盖后**

- 上次运行被中断留下的 `.gamesavesync-previous-*` / `.gamesavesync-stage-*` 会在详情页显示为「发现中断的操作」，可一键恢复旧存档或丢弃。

**其他**

- 解压路径校验：拒绝绝对路径、`..`、反斜杠、Windows 盘符、符号链接条目；写入前再确认最终路径仍在目标目录内。
- 大小限制：单条目/总大小超过 4 GB、解压后超过 8 GB 直接拒绝，避免内存和压缩炸弹问题。
- 「写入 iCloud Drive 文件夹成功」不等于「已上传」：写完后查询 `ubiquitousItemIsUploaded`，未确认时结果文案是「已写入 iCloud Drive，等待上传」，而不是「已上传」。
- 本地存档为空时不允许上传（避免用空目录抹掉云端备份）。

---

## 9. Entitlements 说明

| 平台 | 配置 | 原因 |
| --- | --- | --- |
| iOS | 无 entitlements 文件 | 文件夹访问全部来自系统文件选择器的用户授权，不需要任何特殊能力 |
| macOS | `app-sandbox`、`files.user-selected.read-write`、`files.bookmarks.app-scope` | App Sandbox 是 macOS 上 Security-scoped Bookmark 跨启动生效的前提；后两项只允许访问用户明确选择的文件夹 |

没有 iCloud 容器（`com.apple.developer.icloud-container-identifiers`）、没有 CloudKit、没有网络权限、没有后台模式。

---

## 10. 测试

```bash
# 单元测试（macOS，53 个）
xcodebuild test -project GameSaveSync.xcodeproj -scheme GameSaveSync-macOS -destination 'platform=macOS'

# UI / 端到端测试（iOS 模拟器，6 个；把设备名换成你本机任意一台 iPhone 模拟器）
xcodebuild test -project GameSaveSync.xcodeproj -scheme GameSaveSync-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

覆盖的场景：

| 用例 | 关注点 |
| --- | --- |
| `testUploadWritesManifestAndArchive` | 上传生成 manifest + latest.zip，字段正确 |
| `testRestoreCopiesFilesAndPreservesModificationTimes` | 恢复后文件内容与修改时间保持（误差 < 50 ms） |
| `testRestoreRemovesFilesThatAreNotInTheCloud` | 覆盖时删除云端不存在的本地文件 |
| `testRestoreCreatesLocalFolderWhenMissing` | 新设备首次恢复，本地目录不存在 |
| `testAnalysisDetectsLocalNewer` / `DetectsCloudNewer` | 时间比较方向 |
| `testAnalysisTreatsIdenticalContentAsUpToDate` | 时间不同但内容相同 → 不动 |
| `testSyncReturnsConflictWithoutWriting` | 时间相同内容不同 → 不写任何文件 |
| `testCorruptCloudArchiveIsRejectedAndLocalUntouched` | 云端包被篡改 → 拒绝，本地不变 |
| `testIncompleteManifestBlocksSync` | `status != complete` → 阻断 |
| `testRestoreCreatesLocalSafetyBackup` | 恢复前自动备份，且备份可再恢复 |
| `testHistoryRetentionKeepsConfiguredNumber` | 历史版本只保留 N 份 |
| `testHistoryVersionCanBeRestored` | 从历史版本恢复 |
| `testRestoreFromHistoryChecksumFailureKeepsLocal` | 历史包损坏 → 本地不变 |
| `testUnicodeAndEmptyDirectoriesRoundTrip` | 中文文件名、空目录往返 |
| `testCommitRollsBackWhenStagingIsUnreadable` | 替换失败回滚 |
| `testLeftoverDetectionAndRecovery` | 中断残留检测与恢复 |
| `testPathTraversalIsRejected` / `testAbsoluteAndWindowsPathsAreRejected` | ZIP 路径穿越 |
| `testChecksumMismatchIsDetected` / `testTruncatedArchiveIsRejected` | ZIP 内容损坏 |
| `testNewestFileTimeIsUsedNotFolderTime` | 不使用文件夹时间 |
| `testHashIsStableAndSensitiveToContent` | 时间不变、内容变化也能识别 |
| `testNoiseFilesAreExcluded` | `.DS_Store`、`._*` 等不参与同步 |
| `testDownloadConfirmationRestoresInsteadOfUploading`（UI） | 确认后按推荐方向执行，而不是反向 |
| `testSyncRestoresNewerCloudVersion`（UI） | 真实点击「同步」→ 恢复 → 状态变「已是最新」 |
| `testConflictSheet`（UI） | 冲突弹窗出现 |

---

## 11. 已验证 / 仍需真机验收

**已在模拟器与桌面上验证**

- macOS 与 iOS 两端都能编译通过（Debug / Release）。
- macOS App 可启动、可添加配置、可同步（本地文件夹当作云端根目录时整条链路跑通）。
- iOS 模拟器上：列表/详情/冲突弹窗/确认弹窗/真实同步执行（端到端 UI 测试）。
- 所有文件读写、ZIP 打包解包、校验、回滚逻辑的单元测试。

**必须用真机 + 真实 iCloud Drive 验收（本次无法在本机完成）**

1. **iOS 上通过文件选择器访问其他 App 的 Documents**：取决于目标游戏是否开启文件共享，以及它把存档放在哪个子目录。
2. **Security-scoped Bookmark 在 iOS 上跨启动是否持续有效**：系统可能在 App 更新、重启、iCloud 重新登录后让 bookmark 失效；此时界面会显示「授权文件夹已失效，请重新选择」，需要重新选择授权文件夹。这是设计内的降级路径。
   - 注意区分：书签失效才提示重新授权；如果只是同步文件夹（例如 `saves`）被游戏删掉，界面显示「存档目录不存在」，不会要求重新授权。
3. **免费 Apple ID 签名的 App 是否能正常读写用户选择的 iCloud Drive 文件夹**：代码路径不依赖任何付费能力，但仍需在真机上确认系统没有额外限制。
4. **iCloud 真实上传/下载状态**：`ubiquitousItemIsUploaded`、`ubiquitousItemDownloadingStatus` 在 File Provider 场景下的实际表现、离线时的等待行为、跨设备同步延迟。
5. **后台/锁屏时的 iCloud 同步速度**：App 只在上传后短暂轮询（最长 25 秒），超时会显示「已写入 iCloud Drive，等待上传」，不会假装已上传。
6. **macOS App Sandbox + 用户选择文件夹 + Bookmark 重启恢复**（本机已验证启动，未验证重签名分发后的行为）。

---

## 12. 已知限制

- 不做文件级合并，一个游戏的存档目录视为整体，云端与本地永远只有一份「最新」。
- 不做后台自动同步、不做文件监听。
- 云端历史默认保留 3 份（设置里可调 1–10）；本地备份同样只保留最近 N 份。
- 只处理普通文件和目录；符号链接会被跳过。
- 单个压缩包上限 4 GB（输入）/ 8 GB（解压后），不支持 ZIP64。
- 游戏 ID 一旦在不同设备间不一致，就无法关联到同一份云端备份（添加时会提示云端已有同名 ID 的备份会自动关联）。
- 免费签名 7 天过期，需要重新签名；App 内的配置与备份在重签后保留。

---

## 13. 开发辅助

用示例数据快速查看界面（不影响正常使用，只有显式传入参数时才生效）：

```bash
# macOS
open dist/GameSaveSync.app --args -GSSDemoSeed
```

会生成 5 个不同状态的游戏（仅本机 / 云端较新 / 已是最新 / 冲突 / 需确认），UI 测试也用这个入口。带这个参数启动时示例数据写在临时容器里，不会污染 `~/Library/Containers/com.gamesavesync.app` 下的正常数据；不带参数时看到的就是你自己的真实数据。

日志：`<App 容器>/Library/Application Support/GameSaveSync/Logs/gamesavesync.log`（只记录错误与同步概要）。
