# Psynguechthyngue

原生 SwiftUI 的 iPhone / iPad Syncthing 客户端（iOS / iPadOS 17+，也能以 Designed for iPad 形态运行在 Apple 芯片 Mac 上）。App 在前台运行**未打补丁的上游 Syncthing v2.1.6**，并通过 File Provider 把同步文件夹接入"文件" App。

> **状态：重写中，尚不可发布。** 2026-11 起按 [重写设计](Docs/REWRITE/DESIGN.md) 重做。旧版代码已删除，文档归档在 [Docs/Archive](Docs/Archive/README.md)。做不到或要打折扣的功能见 DESIGN §9。

## 架构一览

- **GoBridge**（`GoBridge/psybridge` → `Artifacts/PsyBridge.xcframework`）：gomobile 只导出少量函数，包括引擎启停、身份、内存配置、全局索引流，以及供扩展使用的受限单文件拉取。上游版本固定在 `GoBridge/SyncthingPin.json`。
- **PsySync**（`Sources/PsySync`，SwiftPM）：契约、`LiveSyncEngine`（走 loopback REST 和事件长轮询）、状态映射、策略、`.stignore` 按需下载，以及 Files 元数据库 `files.sqlite`。
- **App**（`App/`）：4 个 tab 的 SwiftUI 界面、生命周期宿主（进后台停引擎、BGTask）、策略监控、Files domain 管理。
- **File Provider 扩展**（`FileProvider/`）：Replicated extension，只读 `files.sqlite`。文件内容按顺序从三处取：本地 clone、交给 App 下载、扩展内受限小内核拉取。

详见 [Docs/ARCHITECTURE.md](Docs/ARCHITECTURE.md)。

## 环境

- macOS + Xcode（当前在 Xcode 27.2 / iOS 27 Simulator 上验证），部署目标 iOS 17.0
- Go（版本由 `GoBridge/go.mod` 指定，当前为 1.26.2，会自动下载工具链）。所有 go 命令都要加 `-tags noassets`
- Ruby gem `xcodeproj`（用于生成工程）
- 签名：把 `Config/Local.xcconfig.example` 复制为 `Config/Local.xcconfig`（该文件被 git 忽略），填入 Team、Bundle ID 和 App Group

## 构建与验证

```sh
make bootstrap   # 构建 Artifacts/PsyBridge.xcframework（GoBridge 未变时直接跳过）
make project     # 重新生成 Psynguechthyngue.xcodeproj（确定性输出）
make verify      # 完整门禁
```

在全新检出上也可以直接用 `xcodebuild`（或在 Xcode 中构建）：`PsyBridgeBootstrap` target 会在编译前自动生成缺失或过期的 xcframework，`make bootstrap` 只是提前完成这一步。

`make verify` 依次运行：

| 步骤 | 单独运行 | 内容 |
|---|---|---|
| sanity | `make sanity` | 工程与生成器输出一致；没有残留的旧引擎（v1）引用 |
| swift | `make swift-test` | `swift test`（PsySyncTests） |
| go | `make go-test` | `GoBridge/Scripts/test.sh`：vet、单元测试与集成测试、race |
| licenses | `make licenses` | NOTICE、THIRD_PARTY_NOTICES、SBOM 与 GoBridge 实际链接的模块一致 |
| ios | `make ios-build` | Simulator Debug 构建和无签名的 Release 真机构建，并校验产物 |
| ui | `make ui-test` | 在临时创建的 iPhone 和 iPad 模拟器上跑 XCUITest（使用 FakeSyncEngine 夹具，en 与 zh-Hans） |

另有 `make e2e-local`：连接本机官方 Syncthing（`127.0.0.1:8384`）做端到端测试（DESIGN §10.3）。它只创建 `psy-test-*` 资源，并在测试前后对比配置。

## 目录

| 路径 | 内容 |
|---|---|
| `App/` | 主 App（UI、Lifecycle、Files、Notifications、资源） |
| `FileProvider/` | File Provider 扩展 |
| `Platform/PsyBridgeAdapter.swift` | PsyBridge 的 Swift 适配层，App 和扩展都编译它 |
| `Sources/PsySync/`, `Tests/PsySyncTests/` | Swift 引擎与测试 |
| `GoBridge/` | Go bridge 与集成测试 |
| `Tests/PsynguechthyngueUITests/` | UI 测试 |
| `Scripts/` | 构建、验证、工程生成、许可证 |
| `Tools/FilesHarness/` | Files 集成的开发宿主（不在工程内） |
| `Docs/REWRITE/` | 设计、审查记录与各工作包笔记 |

## 许可证

本项目代码以 MIT 许可发布（[LICENSE](LICENSE)）。App 内嵌的 Syncthing 采用 MPL-2.0，其他依赖的许可证见 [NOTICE](NOTICE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，SBOM 在 `Docs/SBOM.spdx.json`。本项目是独立的非官方客户端，与 Syncthing 项目没有隶属关系。
