# 架构

本文概述当前（重写后）的架构。设计理由、接口契约和取舍以 [REWRITE/DESIGN.md](REWRITE/DESIGN.md) 为准。旧架构见 [Archive](Archive/README.md)。

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

不变式（DESIGN §1.1）：

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
| 引擎 | `Sources/PsySync/Live` | `LiveSyncEngine`：REST、事件、状态映射（§5.2）、设备、文件夹、邀请、按需下载（`.stignore`）、Keychain 身份（可迁移旧身份） |
| 策略 | `Sources/PsySync/Policy` | 纯函数 `DefaultSyncPolicy`，只输出暂停/恢复和限速 |
| 外部目录 | `Sources/PsySync/Folders` | security-scoped 书签；拒绝 iCloud 和其他 File Provider 位置 |
| Files 数据 | `Sources/PsySync/Files` | files.sqlite（分页、changes、identity）、EngineLock、路径包含校验 |
| 生命周期 | `App/Lifecycle` | 前台启动；后台在 beginBackgroundTask 内停止；BGTask；Mac 上关窗时也会停止 |
| Files（App 侧） | `App/Files` | 每个文件夹一个 domain，`signalEnumerator`，投影器和请求服务 |
| 扩展 | `FileProvider/` | NSFileProviderReplicatedExtension |
| UI | `App/UI` | 4 个 tab（DESIGN §7）；测试时用 `-PsyUITestFixture` 注入 FakeSyncEngine |

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

见 DESIGN §10：

- `swift test`（PsySyncTests，含穷举的策略测试和 10 万项 files.sqlite 测试）
- `GoBridge/Scripts/test.sh`（含与上游实例互连的集成测试）
- `make e2e-local`（连接本机官方 Syncthing）
- XCUITest（FakeSyncEngine 夹具）
- 真机测量（扩展 RSS、后台停止耗时、BGTask）只能手动做，不进 CI

## 5. 隐私与安全要点

- REST 只监听 127.0.0.1，API key 每次启动随机生成，只存在内存里，日志中会脱敏。
- 设备身份（证书和私钥）存在共享 Keychain access group 中，App 和扩展共用。
- 全局发现和中继默认开启，可在"设置 ▸ 高级"中关闭（DESIGN §12 Q1）。
- 隐私清单：`App/Resources/PrivacyInfo.xcprivacy`、`FileProvider/Resources/PrivacyInfo.xcprivacy`。

## 6. 从旧版升级

重写版首次启动时清理旧数据（DESIGN §8.4）：

1. 删除旧的 File Provider domain。
2. 删除 App Group 中旧布局的目录。
3. 沿用 Keychain 里的旧设备身份，所以设备 ID 不变。
4. 文件夹需要重新配置。

由 App 负责实现，见 `Docs/REWRITE/notes/wp-e-legacy-cleanup.md`。
