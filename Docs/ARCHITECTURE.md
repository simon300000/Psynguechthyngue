# 架构

本文描述当前代码的架构，以及已知的平台限制。契约见各模块源码中的协议和注释（`Sources/PsySync/Engine/`、`Sources/PsySync/Files/FilesContracts.swift`）。

## 1. 进程与组件

```
App 进程 (Psynguechthyngue.app)
  SwiftUI（同步 / 设备 / 文件夹 / 设置） ── AppModel (@MainActor)
  LiveEngineHost ◄─ scenePhase / BGTask / memoryWarning；PolicyMonitor → DefaultSyncPolicy
  LiveSyncEngine (actor, PsySync)
     ├─ PsyBridgeAdapter → PsyBridge.xcframework → 上游 syncthing.App（v2.1.6，无补丁）
     ├─ SyncthingRESTClient → http://127.0.0.1:<随机端口>，每次启动随机 API key
     └─ EventPump：/rest/events 长轮询 → EngineEvent
  FilesIntegration：全局索引 → files.sqlite 投影；处理扩展的请求和本地变更日志
        │ App Group
        ▼
  Engine/（config、索引 DB、engine.lock）  Folders/<id>/  Staging/  Files/files.sqlite
        ▲
File Provider 扩展 (PsyFileProvider.appex)
  枚举：只读 files.sqlite
  取内容：localClone | delegatedToApp | restrictedFetch（受限小内核，持 EngineLock）
  写入：直接写 Folders/<id>/，同时记变更日志并发 Darwin 通知，由 App 定向扫描后上传
```

不变式：

1. `Engine/` 同一时刻只有一个进程能打开，由 `engine.lock` 上的 flock 保证。
2. iOS 进后台前必须停止引擎并释放锁，否则会因 0xdead10cc 被杀。
3. `files.sqlite` 的全局投影只由 App 写入。
4. 扩展从不调用 REST。
5. 策略只调用 `SyncEngine.apply(PolicyDecision)`。
6. REST 只绑定 loopback。

## 2. 模块

| 模块 | 位置 | 说明 |
|---|---|---|
| Go bridge v2 | `GoBridge/psybridge` | 启停上游 App，生成身份，管理 GOMEMLIMIT/GOGC，提供全局索引流、`FetchFile` 和 `RecordFetchedFile`。版本固定在 `SyncthingPin.json` |
| Swift 适配 | `Platform/PsyBridgeAdapter.swift` | 实现 `SyncthingBridge` 和 `RestrictedFetchBridge`；阻塞调用都在专用线程或队列上执行 |
| 引擎 | `Sources/PsySync/Live` | `LiveSyncEngine`：REST、事件、状态映射、设备、文件夹、邀请、按需下载（`.stignore`）、Keychain 身份（可迁移早期版本留下的身份） |
| 策略 | `Sources/PsySync/Policy` | 纯函数 `DefaultSyncPolicy`，只输出暂停/恢复和限速 |
| 外部目录 | `Sources/PsySync/Folders` | security-scoped 书签；拒绝 iCloud 和其他 File Provider 位置 |
| Files 数据 | `Sources/PsySync/Files` | files.sqlite（分页、changes、identity）、EngineLock、路径包含校验 |
| 生命周期 | `App/Lifecycle` | 前台启动；后台在 beginBackgroundTask 内停止；BGTask；Mac 上关窗时也会停止 |
| Files（App 侧） | `App/Files` | 每个文件夹一个 domain，`signalEnumerator`，投影器和请求服务 |
| 扩展 | `FileProvider/` | NSFileProviderReplicatedExtension |
| UI | `App/UI` | 4 个 tab（同步 / 设备 / 文件夹 / 设置）；测试时用 `-PsyUITestFixture` 注入 FakeSyncEngine |

## 3. 构建

- `Scripts/generate-xcodeproj.rb` 生成 `Psynguechthyngue.xcodeproj`，输出是确定性的，`make sanity` 会检查它与已提交的工程一致。工程包含以下 target：
  - `Psynguechthyngue`：App
  - `PsyFileProvider`：扩展
  - `PsynguechthyngueUITests`
  - `PsyBridgeBootstrap`：GoBridge 的输入变化时才重建 xcframework

  App 和扩展都链接 SwiftPM 产品 `PsySync`，并静态链接 `PsyBridge.xcframework`。
- 标识符：`Config/Base.xcconfig` 提供公共设置。`Local.xcconfig`（git 忽略）、`CI.xcconfig`（无签名）、`UITests.xcconfig`（ad-hoc 签名）分别提供 Bundle ID 和 App Group。
- 扩展的编译条件由 `PSY_FILE_PROVIDER_CONDITIONS` 控制，`PSY_RESTRICTED_FETCH` 用来打开受限拉取。

## 4. 测试



- `swift test`（PsySyncTests，含穷举的策略测试和 10 万项 files.sqlite 测试）
- `GoBridge/Scripts/test.sh`（含与上游实例互连的集成测试）
- `make e2e-local`（连接本机官方 Syncthing）
- XCUITest（FakeSyncEngine 夹具）
- 真机测量（扩展 RSS、后台停止耗时、BGTask）只能手动做，不进 CI

## 5. 隐私与安全要点

- REST 只监听 127.0.0.1，API key 每次启动随机生成，只存在内存里，日志中会脱敏。
- 设备身份（证书和私钥）存在共享 Keychain access group 中，App 和扩展共用。
- 全局发现和中继默认开启，可在"设置 ▸ 高级"中关闭。
- 隐私清单：`App/Resources/PrivacyInfo.xcprivacy`、`FileProvider/Resources/PrivacyInfo.xcprivacy`。

## 6. 身份

设备身份由 `KeychainIdentityStore` 管理：首次启动生成，之后读取同一个 Keychain 条目，所以设备 ID 稳定；早期版本留下的旧格式条目会被读取并迁移。

## 7. 已知限制

这些限制来自 iOS / iPadOS 的平台行为或上游 Syncthing 协议，不是待修的缺陷。

**后台与实时性**

- 没有真正的后台常驻同步。iOS 会挂起后台 App；后台只有 BGTask（时机由系统决定，refresh 约 30 秒）。`BGContinuedProcessingTask` 必须由用户发起，且要用具体标识符注册（通配符会被真机拒绝，见 `App/Lifecycle/BackgroundScheduler.swift`）。
- 因此 App 不在前台时收不到远端变更：Files 里的元数据停在 App 最后一次运行（或最近一次 BGTask）时的状态。
- 在 Files 中编辑或新建的内容，App 没运行时不会上传，要等下次打开 App 或 BGTask。
- iOS 没有 FSEvents：本机变更靠扩展写入的变更日志加定向扫描，另有进前台时的扫描。别的 App 直接改写外部目录时，要等下次扫描才会发现。

**Files 与按需下载**

- App 没运行时从 Files 打开未下载的文件，依赖受限小内核：对端要在线且可连接（可能走 relay，较慢）、对端仍有该版本，文件不超过 2 GiB，90 秒内完成（等首个连接最多 20 秒），内存上限 40 MiB。失败时扩展提示"打开 App"。受限拉取不能续传。
- 一次只拉取一个文件；连续打开很多未下载文件会排队，比较慢。
- App 进入后台后不久（实测约 8 秒），系统会取消 App 发起的 Files 下载，条目回到云图标；Files 里的下载进度圈只在 App 仍在运行时可见（iPad 分屏 / 台前调度，或后台继续同步）。
- "为本机文件请求物化"（`requestDownloadForItem`）在 iOS 27 上生效；iOS 26.x 会确认请求但不执行，文件仍显示云图标，打开时由本地克隆即时提供。大文件夹物化速度受系统节奏限制（约 10 项/秒）。
- 按需模式用 `.stignore` 实现：切换到按需时本地有多少文件就写多少条放行规则；规则数很大时上游的匹配性能没有在真机上测量过。上游会保留被忽略的 `.syncthing.*.tmp`，默认 24 小时后才清理。
- 被本机忽略的文件仍出现在 Files 的全局索引投影中；在 Files 里打开会走受限拉取，文件写入文件夹，但引擎不会同步它。
- 外部目录（直接同步）不支持按需下载，也不建 File Provider domain；不能在托管文件夹与外部目录之间切换。
- 不支持把 iCloud Drive 或其他云盘 / 第三方 File Provider 目录作为同步位置（dataless 文件与协调写入的语义冲突），`ExternalLocation` 会拒绝。
- 按需文件夹中尚未下载的文件不提供删除、改名、移动，以免被静默撤销。

**协议与上游**

- Syncthing 协议没有 rename 的身份信息：远端改名在 Files 里表现为删除后新建。
- 上游 v2.1.6 不保存对端通告的 MaxSequence，且我们不给上游打补丁，所以"已收到 / 总数"里的总数拿不到；文件夹的上传速率也拿不到（上游不按文件夹统计）。
- 策略（`DefaultSyncPolicy`）只能整体暂停或限速，不能按文件区分，也没有"低数据模式只同步小文件"。
- 本机不作为别人的中继或全局发现服务器。

**Mac（Designed for iPad）**

- 关闭最后一个窗口会退出 App 并停止同步，没有开机自启或菜单栏常驻；要做到需要原生 macOS 菜单栏 App。
- BGTaskScheduler 在 Mac 上拒绝所有请求，后台调度被跳过。
- File Provider domain 在 Mac 上默认处于用户禁用状态，需要在"系统设置 ▸ 登录项与扩展 ▸ File Providers"中启用；App 会显示提示（见 `App/Files/FilesLocationStatusProvider.swift`）。
