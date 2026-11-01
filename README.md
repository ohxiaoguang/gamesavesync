# GameSaveSync

把 iPhone / iPad / Mac 上同一款游戏的存档文件夹，备份到**你自己的 GitHub 私有仓库**的工具。

- 原生 Swift + SwiftUI，iOS / iPadOS / macOS 共用一套界面、数据模型和同步逻辑。
- 不接入游戏本体，不需要自建服务器，不需要登录第三方服务；只用一个仓库 + 一个 Fine-grained PAT。
- 云端就是普通的 Git 提交历史：每个版本是一个 commit，可以查看、比较、回滚，不需要 App 也能取回文件。
- 不申请 iCloud 容器、CloudKit 等付费开发者专属能力，免费 Apple ID 签名即可安装。
- 所有同步都由用户主动点击触发，没有后台常驻、没有文件监听。

---

## 1. 功能

| 功能 | 说明 |
| --- | --- |
| 游戏管理 | 名称 + 唯一游戏 ID + 本机存档文件夹；新增 / 编辑 / 删除配置（默认不删真实存档） |
| 目录授权 | iOS 用系统文件选择器（`UIDocumentPickerViewController`），macOS 用 `NSOpenPanel`；保存 Security-scoped Bookmark，重启后恢复；失效时提示重新选择 |
| 远端仓库 | 在设置里填 Owner / Repository / Branch + Fine-grained PAT，可随时更换、删除、测试连接 |
| 同步 | 整文件夹覆盖 + 最新存档优先；本地较新→上传，远端较新→恢复，内容相同→不动，时间相同内容不同→用户选择 |
| 强制覆盖 | 「上传」强制用本地覆盖远端，「恢复」强制用远端覆盖本地，执行前明确提示 |
| 安全 | 覆盖前自动备份、压缩包与清单同一次提交、按 commit 读取、字节数与 SHA-256 双重校验、解压校验、原子替换、失败回滚、中断恢复 |
| 历史 | 远端的每个 commit 就是一个历史版本，可分页查看（每次 10 个）并恢复；本地也保留最近 N 份覆盖前快照 |
| 界面 | 原生 SwiftUI，浅色/深色，中文/英文（可跟随系统或在设置里切换），iPhone / iPad / Mac |

---

## 2. 环境与本次验证

| 项目 | 值 |
| --- | --- |
| Xcode | 27.1 (17A9275) |
| Swift | 6.4（工程使用 Swift 5 语言模式 + `SWIFT_STRICT_CONCURRENCY=minimal`） |
| 部署目标 | iOS 17.0 / macOS 14.0 |
| 构建产物 | macOS 通用二进制（arm64 + x86_64，ad-hoc 签名 + App Sandbox）；iOS arm64 `.app` → 未签名 IPA |
| 单元测试 | 110 个，全部通过（macOS 逻辑测试，GitHub 接口用 `URLProtocol` 模拟） |
| UI 测试 | 11 个，全部通过（iPhone 模拟器） |

---

## 3. 目录结构

```text
gamesavesync/
├── project.yml                     # XcodeGen 工程描述
├── GameSaveSync.xcodeproj          # 已生成的工程，可直接打开
├── GameSaveSync/
│   ├── Shared/
│   │   ├── Models/                 # Game / AppSettings / SaveSnapshot / CloudManifest / 同步模型
│   │   ├── Services/               # 目录授权、配置存储、扫描、备份、GitHub API 与存储、Keychain
│   │   ├── Sync/                   # 决策、同步引擎、RemoteStore 协议、目录替换、ZIP 读写
│   │   ├── Views/                  # 列表 / 详情 / 编辑器 / 设置 / 冲突 / 目录选择
│   │   ├── App/                    # AppModel（@Observable）+ 开发用示例数据
│   │   └── Support/                # 本地化、格式化、哈希、日志
│   ├── iOS/                        # iOS 入口 + Info.plist
│   ├── macOS/                      # macOS 入口 + Info.plist + entitlements
│   └── Resources/                  # Assets（App 图标、强调色）
├── GameSaveSyncTests/              # 单元测试（含模拟 GitHub 服务的 URLProtocol）
├── GameSaveSyncUITests/            # 界面与端到端流程测试
├── scripts/
│   ├── build.sh                    # 一键构建 macOS App + 未签名 IPA
│   └── make-icon.swift             # 生成 App 图标
└── dist/                           # 构建产物
```

核心模块职责：

- `ConfigurationStore`：`games.json` / `settings.json` 的读写。
- `DirectoryAccessManager` / `LocalAccessResolver`：Bookmark 创建/解析、Security Scope 生命周期、授权根目录与同步子目录的分离。
- `GitHubAPIClient`：GitHub REST 调用、请求重试、错误归类、大文件 base64 请求体落盘。
- `GitHubStorageManager`：`games/<gameId>/` 的读、写、历史，以及提交的原子性。
- `GitHubCredentialStore`：PAT 的 Keychain 读写（不落 `settings.json`、不写日志）。
- `RemoteStore`：远端抽象，`GitHubStorageManager` 是正式实现，`DemoRemoteStore` 仅供演示/UI 测试。
- `SaveScanner`：递归扫描、最新文件时间、SHA-256 内容指纹。
- `ArchiveManager`：整目录 ZIP 打包/解包 + 精确时间戳旁路文件。
- `SyncEngine` + `SyncDecisionMaker`：版本比较与执行。
- `BackupManager`：本地安全快照。
- `DirectoryReplacer`：目录内容原子替换与回滚。

---

## 4. 准备私有仓库与令牌

### 4.1 新建私有仓库

1. 打开 <https://github.com/new>。
2. 填 `Repository name`（例如 `game-saves`），选择 **Private**。
3. 不需要勾选 README / .gitignore，**允许仓库完全空白**：首次上传时 App 会先用内容接口写入一个 `.gamesavesync/init.json`，让仓库拥有第一个提交和分支，再提交存档；已有 README 等文件的仓库不会被改动。
4. App 不会替你创建仓库，也不会把存档写进任何你没有明确填写的仓库。

### 4.2 新建 Fine-grained PAT

1. 打开 <https://github.com/settings/personal-access-tokens/new>。
2. `Token name` 随意，`Expiration` 按需（建议 90 天，过期后重新生成并替换）。
3. `Repository access` 选 **Only select repositories**，只勾选上一步的私有仓库。
4. `Permissions` → `Repository permissions` → **Contents: Read and write**（`Metadata: Read-only` 会自动勾上），其余保持 No access。
5. 生成后复制 `github_pat_…`，只显示一次。

> 只需要 `Contents: Read and write`。App 不会读取 Issues、Actions、Secrets，也不会修改仓库设置、协作者或分支保护。

### 4.3 在 iPhone 和 Mac 上各配置一次

设置页 → **GitHub Repository**：

| 字段 | 说明 |
| --- | --- |
| Repository Owner | 仓库所有者的登录名（不是显示名） |
| Repository Name | 仓库名，例如 `game-saves` |
| Branch | 默认 `main`；可以改用别的分支名，两台设备必须一致 |

再填写 **Access Token** → `Save Token`，然后点 **Test Connection**。测试会确认：

- 仓库存在，且属于该 owner；
- 仓库是 **Private**（公开仓库会被拒绝）；
- 令牌可以读取该仓库，并且有写入权限；
- 分支存在（完全空白的仓库会显示为 `main · 空仓库（首次上传自动初始化）`）。

常见错误会分别提示，而不是笼统的「同步失败」：令牌无效/过期、权限不足、仓库不存在、仓库不是私有、分支不存在、限流、网络不可用、超时。

令牌只保存在系统 Keychain（`kSecAttrAccessibleAfterFirstUnlock`，不参与 iCloud 钥匙串同步），不会写进 `settings.json`、`UserDefaults`、源码或日志。点 `Remove Token` 即可清除。

---

## 5. 构建

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

- `dist/GameSaveSync.app`：macOS 应用（ad-hoc 签名，已启用 App Sandbox + 网络客户端权限）。
- `dist/GameSaveSync-unsigned.ipa`：iOS 未签名 IPA（`Payload/GameSaveSync.app`，arm64）。

### 5.1 用免费 Apple ID 安装到 iPhone / iPad

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

> 免费账号的限制来自 Apple 本身：7 天有效期、最多 3 个 App、不能使用 iCloud 容器 / CloudKit / Push 等能力。本 App 只用到 HTTPS 出网与用户选择的本地文件夹，这两项免费账号都支持。

---

## 6. 使用流程

1. **配置仓库**：见第 4 节。iPhone / iPad 与 Mac 填同一个 owner / repo / branch，各自保存一次令牌。
2. **添加游戏**：点右上角 `+`，填游戏名称，游戏 ID 会自动按名称生成（可改，注意两端必须一致），然后分两步选文件夹：
   - **授权文件夹**：建议选游戏自己的 `Documents` 目录（iOS 上是游戏通过「文件」App 暴露的目录；macOS 上可以是 `~/Library/Application Support/...` 之类的任意目录）。App 只对这一层申请一次授权并保存书签。
   - **同步文件夹**：在授权文件夹里逐级浏览，选真正要同步的子目录，例如 `saves`。界面会显示成 `Documents / saves`。也可以直接选授权文件夹本身，此时会提示「将同步整个授权文件夹」。
   - 只有「同步文件夹」里的内容会被上传、备份、覆盖；`cache`、`config.json` 等兄弟文件永远不参与。同步文件夹被游戏删掉后重建，只要相对路径没变，下次仍能直接用。
3. **同步**：主界面每行右侧的循环按钮，或进入详情页点「同步」。
4. **详情页**可以看本地/远端时间、文件数与大小、最近同步结果、远端历史版本（commit）、本地备份，以及强制「上传」「恢复」。
5. **删除配置**只删本机的游戏配置，不删真实存档，也不删 GitHub 上的提交。

主界面只显示状态（一行一个），具体时间和操作都在详情页，避免手机屏幕拥挤。

---

## 7. GitHub 上的数据结构

每个游戏在仓库里占两个文件，目录外的东西不会被读写：

```text
.gamesavesync/
└── init.json                 # 只在空仓库首次初始化时写入一次
games/
├── darkest-dungeon/
│   ├── manifest.json
│   └── save.zip
├── fc-27/
│   ├── manifest.json
│   └── save.zip
└── mario-wonder/
    ├── manifest.json
    └── save.zip
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
  "sourceAppVersion": "1.0.0 (1)",
  "contentHash": "9f2c…",                          // 存档内容 SHA-256
  "fileCount": 12,
  "totalBytes": 1048576,
  "archiveFileName": "save.zip",
  "archiveBytes": 302144,
  "archiveSHA256": "1c7d…",
  "status": "complete"
}
```

**一次上传就是一个 commit**，这个 commit 同时包含新的 `save.zip` 和新的 `manifest.json`：

1. 读取分支 HEAD，并读取该游戏当前的 `manifest.json`；
2. 上传 ZIP blob；
3. 上传 manifest blob；
4. 以**当前分支最新提交的 tree 为 `base_tree`**，创建只替换这两个路径的新 tree；
5. 创建 commit（父提交是刚才读到的最新提交）；
6. 用 `force: false` 快进更新分支。

**完全空白的仓库**：`POST /git/refs` 不允许在没有任何分支的仓库上创建引用（GitHub 文档明确写了这一点），所以第一次写入会先用
`PUT /repos/{owner}/{repo}/contents/.gamesavesync/init.json` 初始化默认分支，再正常提交。若你填的分支不是仓库默认分支，
App 会在这个初始提交上创建该分支。仓库里已有的 README 等文件从不会被覆盖。

因此：

- 其它游戏的目录原样保留，互不影响；
- 任何时刻从某个 commit 读到的 manifest 与 ZIP **一定是同一版本**，不会出现「新清单配旧包」；
- 如果读取之后别的设备先提交了（同一个游戏），本次上传会**中止并提示冲突**，不会覆盖别人的版本；如果只是别的游戏变了，会基于新提交重建一次再试。

ZIP 内部额外带一个 `.gamesavesync-archive.json` 旁路文件，记录每个文件的精确修改时间（ZIP 的 DOS 时间只有 2 秒精度且无时区），解压后据此还原时间戳，然后删除该文件。

---

## 8. 同步判定规则

一次「同步」的实际决策（`SyncDecisionMaker`）：

| 情况 | 判定 | 动作 |
| --- | --- | --- |
| 本地有、远端无 | `upload(.firstSyncLocalOnly)` | **首次上传前确认**，然后上传整个文件夹 |
| 远端有、本地无/本地空 | `download(.firstSyncCloudOnly / .localEmpty)` | 恢复 |
| 两端内容哈希相同 | `upToDate` | 不动（即使时间不同） |
| 本地最新存档时间 > 远端 | `upload(.localNewer)` | 上传 |
| 远端最新存档时间 > 本地 | `download(.cloudNewer)` | 恢复 |
| 时间差 ≤ 2 秒且哈希不同 | `conflict` | 弹出选择：本地 / 远端 / 取消 |
| 两端都有内容但本设备从未与该仓库同步过 | 按时间给出方向 + **强制确认** | 确认后执行 |
| 两端时间差 > 180 天 | `clockSkew` | 提示时钟可能不准，确认后执行 |

判定依据只有两个：**存档文件的最新修改时间** 和 **内容 SHA-256**。commit 时间、ZIP 创建时间、备份生成时间、下载时间都不参与比较。

边界处理：

- 空文件夹：没有文件时时间戳记为 `nil`，用哈希（空集合的哈希）和文件数判断，不会因为「空文件夹的修改时间很新」而误判。
- 时间戳精度：比较容差 2 秒，避免不同文件系统/复制工具截断时间造成假「更新」。
- 时间没变但内容变了：哈希不同 → 冲突或按时间走，不会被当作「已是最新」。
- 时间相同内容相同：直接「已是最新」。
- 旧版（iCloud 目录）留下的「已同步」记录不算作「已与该仓库同步过」：每个游戏会记录上次同步的远端标识（owner/repo/branch），换了仓库或第一次用 GitHub 时仍会先确认一次。
- 每次写入前都会重新读取远端版本；如果分析之后远端变了，会重新判定或直接中止，绝不在没看见的版本上写入。

---

## 9. 安全设计

**读取远端**

- 一次恢复只锁定**一个 commit**：manifest 和 ZIP 都从这个 commit 读，读完先校验字节数与 SHA-256，再解压，再逐文件 CRC 校验，最后重新计算解压目录的内容哈希与 manifest 对比；任一步失败都不触碰本地存档。
- 恢复前会再读一次分支 HEAD，如果与分析时不同就报「远端已更新」，让你重新同步，而不是悄悄回滚。
- `status` 不是 `complete` 的清单一律拒绝使用；归档文件名会被清理，防止清单里的路径跑出游戏目录。
- 只下载当前游戏的两个文件，不 clone 仓库、不拉取其它游戏。

**覆盖前**

- 先把当前本地存档完整复制到 App 容器的 `Backups/<gameId>/<时间>-<随机>/Payload`，并重新扫描校验哈希一致；校验不一致（例如拷贝过程中游戏还在写盘）就中止，什么都不改。

**覆盖中**

- 新内容先解压到**目标文件夹内部**的 `.gamesavesync-stage-<uuid>/`。这样不需要父目录写权限（iOS 的授权只覆盖所选文件夹及其子项），也不跨卷。
- 替换时把旧文件移到 `.gamesavesync-previous-<uuid>/`，再把新文件移入；全部成功才删除旧目录。任何一步失败都按相反顺序移回，返回「已回滚」或「回滚失败，文件仍保留在 xxx」。

**覆盖后**

- 上次运行被中断留下的 `.gamesavesync-previous-*` / `.gamesavesync-stage-*` 会在详情页显示为「发现中断的操作」，可一键恢复旧存档或丢弃。

**其他**

- 解压路径校验：拒绝绝对路径、`..`、反斜杠、Windows 盘符、符号链接条目；写入前再确认最终路径仍在目标目录内。
- 大小限制：单条目/总大小超过 4 GB、解压后超过 8 GB 直接拒绝，避免内存和压缩炸弹问题。
- 本地存档为空时不允许上传（避免用空目录抹掉远端备份）。
- 令牌只放在 Keychain；请求只带 `Authorization: Bearer`，日志里不会出现令牌或带令牌的 URL。

**大小限制**

| 阈值 | 行为 |
| --- | --- |
| 压缩包 ≥ 50 MiB | 界面上给出体积提示 |
| 压缩包 ≥ 100 MiB | 直接拒绝并说明原因（GitHub 单个 blob 上限），不会上传 |
| 压缩包大小 | 在访问网络之前就检查，大文件不会先在内存里膨胀 |

上传时的 base64 请求体会写到临时文件后再流式发送，下载直接写入磁盘文件，因此大存档不会因为 base64 编码而占用双倍内存。不使用 Git LFS（免费账号与 PAT 配置都更容易出错，且历史版本会变成指针文件）。

---

## 10. 错误处理

| 场景 | 提示 |
| --- | --- |
| 网络不可用 / 请求超时 | 分别提示，可重试；超时后会先查询远端状态再决定是否重试 |
| 令牌无效或过期（401） | 提示重新生成令牌 |
| 权限不足（403） | 提示需要 `Contents: Read and write` |
| 仓库不存在 / owner 不匹配（404） | 指出是哪个 owner/repo |
| 分支不存在（404） | 指出分支名，提示在 GitHub 上创建或改填已有分支 |
| 仓库不是私有 | 明确拒绝，要求换成 Private 仓库 |
| 远端在分析后更新（409/422） | 提示「远端已更新」，重新同步，绝不覆盖 |
| 限流（429 / 403 + `x-ratelimit-remaining: 0`） | 说明剩余等待时间；只对可安全重试的 GET 做有限次退避重试 |
| 文件过大（≥ 100 MiB） | 说明上限与实际大小 |
| 压缩包损坏 / 校验失败 | 中止恢复，本地不变 |
| 未配置仓库或令牌 | 引导到设置页，而不是报网络错误 |

---

## 11. Entitlements 说明

| 平台 | 配置 | 原因 |
| --- | --- | --- |
| iOS | 无 entitlements 文件 | 文件夹访问全部来自系统文件选择器的用户授权；访问 GitHub 用普通 HTTPS，不需要额外能力 |
| macOS | `app-sandbox`、`files.user-selected.read-write`、`files.bookmarks.app-scope`、`com.apple.security.network.client` | App Sandbox 是 Security-scoped Bookmark 跨启动生效的前提；网络客户端权限用于访问 `api.github.com` |

没有 iCloud 容器（`com.apple.developer.icloud-container-identifiers`）、没有 CloudKit、没有后台模式、没有 Keychain Sharing（令牌只在本机 App 内使用）。

---

## 12. 测试

```bash
# 单元测试（macOS，110 个）
xcodebuild test -project GameSaveSync.xcodeproj -scheme GameSaveSync-macOS -destination 'platform=macOS'

# UI / 端到端测试（iOS 模拟器，11 个；把设备名换成你本机任意一台 iPhone 模拟器）
xcodebuild test -project GameSaveSync.xcodeproj -scheme GameSaveSync-iOS \
  -destination 'platform=iOS Simulator,name=iPhone 15 Pro'
```

GitHub 相关的单元测试把生产代码（`GitHubAPIClient` + `GitHubStorageManager`）接到一个基于 `URLProtocol` 的内存 Git 服务上：真实的请求构造、状态码映射、blob/tree/commit 语义、并发与重试都在测试里跑，不需要网络也不需要真令牌。

覆盖的场景：

| 用例 | 关注点 |
| --- | --- |
| `testTokenNeverLandsInSettings` / `testKeychainStorePersistsAndDeletes` | 令牌只在 Keychain，`settings.json` 里没有 |
| `testEmptyRepositoryReportsNoCommit` / `testEmptyRepositoryIsInitialisedBeforeTheFirstSaveCommit` | 空仓库用内容接口初始化，不依赖 `POST /git/refs` |
| `testInitialUploadLeavesExistingRepositoryFilesAlone` | 已有 README 等的仓库首次上传不被改动，也不会重复初始化 |
| `testConfiguredBranchIsCreatedWhenItIsNotTheDefaultBranch` | 填写的分支不是默认分支时，在初始提交上创建该分支 |
| `testTwoDevicesCanInitialiseTheSameEmptyRepository` | 两台设备同时面对空仓库都能成功，互不丢版本 |
| `testLostConnectionDuringUploadCreatesNoCommit` | 上传时断网 → 分支不动，不产生提交 |
| `testConnectionRejectsPublicRepository` / `testConnectionReportsMissingRepository` / `testConnectionWithInvalidTokenIsReportedAsAuthenticationFailure` | 私有性、404、401 分别提示 |
| `testConnectionReportsReadOnlyToken` / `testPermissionDeniedIsReported` / `testRateLimitIsReportedAfterBoundedRetries` / `testUnprocessableResponseIsReported` | 只读令牌、403、限流与有限重试、422 |
| `testSecondCommitIsFastForward` / `testSameContentIsNotReuploaded` | 快进提交、内容未变不重复提交 |
| `testManifestAndArchiveLiveInTheSameCommit` | 清单与压缩包在同一 commit，且旧 commit 保持旧内容 |
| `testSecondUploadKeepsOtherGamesIntact` / `testUnrelatedCommitIsRebasedInsteadOfFailing` | 其它游戏与其它设备提交不被破坏 |
| `testConcurrentUploadOfTheSameGameIsNeverOverwritten` / `testForcedUploadAbortsWhenTheSameGameChangedAfterAnalysis` | 同一游戏并发写入 → 中止（含强制上传），别人版本保留 |
| `testUncertainTimeoutDoesNotCreateASecondCommit` | 超时后先查远端，不产生重复 commit |
| `testDownloadUsesTheRequestedCommit` / `testDownloadRejectsAnArchiveThatDoesNotMatchItsManifest` | 按指定 commit 读取、校验失败即拒绝 |
| `testRestoreCopiesFilesAndPreservesModificationTimes` | 恢复后文件内容与修改时间保持（误差 < 50 ms） |
| `testRestoreRemovesFilesThatAreNotOnTheRemote` | 覆盖时删除远端不存在的本地文件 |
| `testRestoreCreatesLocalFolderWhenMissing` | 新设备首次恢复，本地目录不存在 |
| `testAnalysisDetectsRemoteNewerThanLocal` / `testAnalysisDetectsLocalNewer` | 时间比较方向 |
| `testAnalysisTreatsIdenticalContentAsUpToDate` | 时间不同但内容相同 → 不动 |
| `testSyncReturnsConflictWithoutWriting` | 时间相同内容不同 → 不写任何文件 |
| `testFirstUploadOfAGameWithNoRemoteCopyAsksForConfirmation` | 首次上传必须确认，不会静默上传 |
| `testLostConnectionDuringRestoreLeavesLocalSavesUntouched` | 恢复时断网 → 本地存档不变 |
| `testLegacySyncRecordDoesNotSkipTheFirstGitHubConfirmation` | 旧的 iCloud 同步记录不算作已与该仓库同步 |
| `testCorruptRemoteArchiveIsRejectedAndLocalUntouched` | 远端包被篡改 → 拒绝，本地不变 |
| `testIncompleteManifestBlocksSync` | `status != complete` → 阻断 |
| `testRestoreCreatesLocalSafetyBackup` | 恢复前自动备份，且备份可再恢复 |
| `testHistoryIsOneCommitPerUploadAndCanBeRestored` | 每次上传一个 commit，可从旧 commit 恢复 |
| `testHistoryPagingReturnsTenAtATime` | 历史分页 10 条 |
| `testRestoreFromHistoryChecksumFailureKeepsLocal` | 历史包损坏 → 本地不变 |
| `testUnicodeAndEmptyDirectoriesRoundTrip` | 中文文件名、空目录往返 |
| `testArchiveAboveTheGitHubLimitIsRejectedBeforeAnyRequest` | ≥ 100 MiB 在联网前拒绝 |
| `testLegacySettingsAreMigratedWithoutLosingChoices` / `testLegacyGamesJSONKeepsEveryGame` / `testSyncKindDecodingIsTolerant` | 旧 `settings.json` / `games.json` 可读，历史保留份数迁移为本地保留份数 |
| `testDefaultRepositoryIsNeverTheSourceRepository` / `testRepositoryValidation` | 不会默认指向源码仓库，字段校验 |
| `testCommitRollsBackWhenStagingIsUnreadable` / `testLeftoverDetectionAndRecovery` | 替换失败回滚、中断残留检测与恢复 |
| `testPathTraversalIsRejected` / `testAbsoluteAndWindowsPathsAreRejected` | ZIP 路径穿越 |
| `testChecksumMismatchIsDetected` / `testTruncatedArchiveIsRejected` | ZIP 内容损坏 |
| `testNoiseFilesAreExcluded` | `.DS_Store`、`._*` 等不参与同步 |
| `testDownloadConfirmationRestoresInsteadOfUploading`（UI） | 确认后按推荐方向执行，而不是反向 |
| `testSyncRestoresNewerRemoteVersion`（UI） | 真实点击「同步」→ 恢复 → 状态变「已是最新」 |
| `testConflictSheet`（UI） | 冲突弹窗出现 |
| `testSettingsConfiguresTheGitHubRepository`（UI） | 设置页是 GitHub 配置，且没有任何 iCloud 字样 |
| `testRemoteHistoryListsCommits`（UI） | 详情页把远端历史显示为 commit 列表 |

---

## 13. 已验证 / 仍需真机验收

**已在模拟器与桌面上验证**

- macOS 与 iOS 两端都能编译通过（Debug / Release）。
- 110 个单元测试、11 个 UI 测试全部通过。
- macOS App 可启动、可添加配置、可同步（用内置演示远端跑通整条链路）。
- iOS 模拟器上：列表/详情/冲突弹窗/确认弹窗/真实同步执行（端到端 UI 测试）。

**必须用真实私有仓库 + 真机验收（本次未做，需要你的仓库和令牌）**

1. **真实 `api.github.com` 往返**：模拟服务按 GitHub 文档实现，但真实服务的限流头、空仓库初始化、代理与 CDN 仍需实测。
2. **Fine-grained PAT 的权限组合**：确认只有 `Contents: Read and write` + `Metadata: Read` 时能提交，且缺少写权限时提示正确。
3. **iOS 上通过文件选择器访问其他 App 的 Documents**：取决于目标游戏是否开启文件共享，以及它把存档放在哪个子目录。
4. **Security-scoped Bookmark 在 iOS 上跨启动是否持续有效**：系统可能在 App 更新、重启后让 bookmark 失效；此时界面会显示「授权文件夹已失效，请重新选择」。这是设计内的降级路径。
   - 注意区分：书签失效才提示重新授权；如果只是同步文件夹（例如 `saves`）被游戏删掉，界面显示「存档目录缺失」，不会要求重新授权。
5. **两台设备同时同步同一款游戏**：代码里有冲突中止与重试，但真实网络下的时序需要跑一次确认。
6. **免费 Apple ID 签名 + App Sandbox**：macOS 重签名分发后的 Bookmark 与网络权限表现。
7. **大存档**：接近 50 MiB 的提示、接近 100 MiB 的拒绝，以及上传耗时。

---

## 14. 已知限制

- 不做文件级合并，一个游戏的存档目录视为整体，远端与本地永远只有一份「最新」。
- 不做后台自动同步、不做文件监听。
- 远端历史 = Git 提交历史，不做清理：仓库体积会随上传次数增长，需要时可在 GitHub 网页上删除旧 commit 或重建仓库。
- 本地备份保留份数可调（1–10，默认 3）。
- 只处理普通文件和目录；符号链接会被跳过。
- 单个压缩包上限：≥ 50 MiB 提示，≥ 100 MiB 拒绝；不支持 Git LFS。
- 单个解压后目录上限 8 GB，单个条目 4 GB，不支持 ZIP64。
- 游戏 ID 一旦在不同设备间不一致，就无法关联到同一份远端备份（添加时会提示）。
- 免费签名 7 天过期，需要重新签名；App 内的配置、Keychain 里的令牌与本地备份在重签后保留。

---

## 15. 开发辅助

用示例数据快速查看界面（不影响正常使用，只有显式传入参数时才生效）：

```bash
# macOS
open dist/GameSaveSync.app --args -GSSDemoSeed
```

会生成 5 个不同状态的游戏（仅本机 / 远端较新 / 已是最新 / 冲突 / 需确认），并使用一个存在于 App 容器里的**演示远端**（`DemoRemoteStore`），不会访问 GitHub。UI 测试也用这个入口。带这个参数启动时示例数据写在临时容器里，不会污染 `~/Library/Containers/com.gamesavesync.app` 下的正常数据；不带参数时看到的就是你自己的真实数据。

日志：`<App 容器>/Library/Application Support/GameSaveSync/Logs/gamesavesync.log`（只记录错误与同步概要，不含令牌）。
