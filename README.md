# Psynguechthyngue

2026-10-19：前台同步生命周期、文件索引读取和核心使用流程已重构。架构、逐项检查和本轮验证见 [重构检查](Docs/REFACTOR_REVIEW.md)；此前记录保留为历史检查点。

Psynguechthyngue 是一个正在开发的原生 SwiftUI iPhone/iPad Syncthing 兼容客户端，最低系统为 iOS/iPadOS 17；主 App 也显式支持在 Apple 芯片 Mac 上以 Designed for iPad 形态运行。它把固定版本的 Syncthing Go core 嵌入 App，并实现 Swift 状态投影、replicated File Provider、统一策略、App Intents、后台机会运行和用户授权外部目录的受控镜像。

> **尚未达到可发布或可承载重要数据的状态。** 当前实现已经不是静态 Demo：此前隔离检查点中的 Simulator 与标准 Desktop Syncthing 完成了真实双向 create/modify/rename/delete；当前宿主 SwiftPM、strict format、fresh Mobilebridge v2.1.3、项目一致性、许可证与源码包门禁均通过。2026-08-20 至 21 日在指定 `t` 的真实 Files 中确认：iOS 会把多个 File Provider domains 聚合为同一个 provider entry，因此当前源码使用一个 aggregate domain，并在根目录为每个 Syncthing share 显示独立文件夹 entry。Files 创建/重命名 `Final-create` 和系统“保存到文件”的普通文本均成功；把两个现有 share 显式分享给已接受的 Desktop peer 后，普通文件及目录实际传播到标准 Syncthing v2.1.3 peer。Desktop 创建的 43-byte 文件在 Files 中完成 placeholder 打开、Keep Downloaded、Remove Download、恢复为 cloud placeholder 和再次打开。该链证明系统 File Provider 的占位、释放与再读取，不单独证明 managed root 始终 dataless 或纯网络取回。设备 crash log 揭示的 `invalidate()` 持锁 `0xdead10cc` 已修复。写盘问题仍是发布阻塞：09:37 的第五份 `diskwrites_resource` 报告发生在 metadata cache 优化安装之后，匹配 Go 符号后重栈是 Syncthing `sendReceiveFolder.performFinish`，推翻了先前的 SQLite 枚举根因假设。当前进一步限制 File Provider owner 只能领取 File Provider 自己创建的队列命令，普通用户/BG sync 留给 App/BGTask；长期真机资源预算仍需重验。自然 BGTask 生命周期、第三方 provider、完整 modify/move/delete 矩阵和冻结 release 门禁仍未完成；iPad 对称 Files 路径按用户批准豁免，Android peer 已移出 v1.0 验收范围。严格完成判据见 [v1.0 完成定义](goal-objective.md)，准确证据和缺口见[实现状态](Docs/IMPLEMENTATION_STATUS.md)与[测试矩阵](Docs/TEST_MATRIX.md)。

## 当前能力边界

已经实现并有自动化覆盖的有限范围包括：

- 固定到精确 commit 的 Syncthing core；关闭管理 HTTP、自动升级、使用情况和崩溃上报。
- Keychain 托管的 opaque identity、稳定 Device ID，以及设备/文件夹增删改、暂停/恢复、重扫。本机和 peer 设备 ID 均可显式复制或通过系统分享；手工输入、二维码扫描和设备 Shortcuts 使用与固定 Syncthing core 相同的 Base32/Luhn32 校验并统一为 canonical 8×7 ID，错误校验字符不会入队。设备详情和状态 Intent 会显示 core 按可见 folders 聚合的真实待上传字节，以及由相邻完整 connection counter 样本计算的每设备上传/下载速率；速率只在 embedded core 发布 network snapshot 时采样，不伪装成连续实时遥测。
- 待接受设备/文件夹投影、接受和抑制：configured device 可通过 zero-folder、最多 8 MiB 协议流量的 discovery session 获取只供展示的 pending-folder summaries；接受/忽略仍必须建立独立 live observation proof，并以 `offerVersion`/`suppressionVersion`、configuration revision 和 offering device 精确重验。设备不采纳远端地址，文件夹只使用 App Group 托管路径和用户显式选择的 configured peers；ignore/unignore 会投影可审计的 suppressed state。恰好带一个加密方向 token 的 offer 可按 `receiveEncrypted` 接受，且只绑定已验证的 offering device；双 token、明文类型错配和过密重扫会在配置提交前拒绝。接收端不请求或保存发送端密码；发送端为不可信设备配置密码的流程仍未暴露。
- bridge-owned JSON envelope、configuration/network/pending-observation/pending-discovery 显式 session、global/local index 与 event 分页查询、稳定 item ID、版本校验、真实文件 create/modify/intra-folder move/delete、最多 1 MiB 的本地或远端范围读取，以及有界双向 sync slice。所有 JSON 入口在副作用前统一拒绝顶层非对象、任意层重复/转义等价字段、尾随值和超过 64 层嵌套，歧义请求不回显 request ID。network session 绑定单一 folder、configuration revision、task/plan digest 和 native hard byte budget。
- 跨进程 no-follow `flock`、单调 owner epoch/fencing、Swift durable command/result queue、Go 写前 command ledger、崩溃后保守重放与显式 acknowledgement；不确定 File Provider mutation 只通过独立 rescan + authoritative state/staging proof reconciliation，不重放原 mutation。Files create/modify/move/delete 与其 deferred upload 以一个 durable batch 发布：本地 mutation 使用禁用连接服务、暂停全部远端设备且 native byte cap 为 0 的 `localMutation` session 先提交，上传在网络策略允许时另行执行，因此离线/受限网络不会把本地 Files 写入误判为网络任务。
- SQLite WAL 元数据投影、keyset pagination、搜索、tombstone/change journal、移动时旧父目录删除通知，以及默认 100,000 项回归和可显式运行的 1,000,000 项压力门禁。
- File Provider 的枚举、按 Files 打开触发的 materialization、create/modify/同文件夹 move/delete 回写源码；每个 mutation 在 staging/enqueue 前与 native 执行前绑定并重验 configuration revision 和 folder incarnation，folder 被删除后以同 ID 重建也会使旧 callback fail closed。上传 staging 会在跨进程锁内预留两份内容加 256 MiB，用 no-follow descriptor/SHA-256 检查重试与 swap，并只清理超过 24 小时且不被 pending/reconciliation 引用的目录。Go bridge 另提供脱敏、分页的 mutation recovery 清单、精确确认处置和内容围栏临时快照导出；Swift 只收到 opaque export URL，系统分享结束或下次启动时通过 native exact-ID cleanup 清理，不暴露隐藏 recovery locator，也不改变 retained source 或 live item。“移除下载”只消费当前 exact `isUploaded`，随后调用系统 `evictItem`，并在系统成功后撤销本机 source authority。
- 七种内容选择模式现在只控制移动设备本机保留：Full/Pinned Offline 保留整个文件夹，Manual/Glob/RE2-safe Regex 对 global-index metadata 求值并保留匹配项目，Index Only 只维护占位符，On Demand 打开时下载但不自动 pin。Apply/Rollback 会提交真实 retention generation 并推进有界 reconciliation；计划派生下载不会被固化成 per-item explicit pin，只有用户单独 Keep Downloaded 才跨后续计划持续。手动选择树、debounced 搜索、三态投影和大批量修改移出主线程，100,000 项 host 投影回归通过。App 永不生成、解析或重写用户 `.stignore`；Selective 模式继续交换索引和上传本地修改，精确 pinned item 通过独立 materialize 命令下载。
- File Provider 全部 global-index 文件以本机内容或 dataless placeholder 展示。`ContentRetentionStore` 跨 App/extension/BGTask/Intent 保存 pin、目录继承、规则 generation、`pendingEvict` 和可恢复 eviction transaction；当前 exact `isUploaded` 是“移除下载”的唯一资格。已上传版本立即逐文件释放，未上传版本等待 peer 确认后自动释放；“删除”使用独立 Syncthing tombstone 路径并明确传播到 peers。详见 [ADR-0008](Docs/ADR/0008-file-provider-retention-and-eviction.md)。
- File Provider 注册一个用户可达的 aggregate domain；其根目录按 authoritative snapshot 枚举每个唯一 Syncthing share 为独立文件夹 entry。share folder identifier 由 folder ID 稳定、不透明地派生；目录内的枚举、直接 item 查询、materialization、mutation、custom action 与 parent normalization 都重验 exact folder scope，跨 share reparent 不广告并 fail closed。App 启动时先安装 aggregate replacement，再逐个注销旧 `share-v1-*` domains；某个被 Files 占用的旧 domain 删除失败不会阻止其他迁移，后续前台机会精确重试。该结构已在 `t` 以两个可区分 share entries 通过，而不是把 iOS 不提供的多个侧边栏位置写成产品能力。
- security-scoped bookmark、能力探测、协调 I/O、controlled/import-only/export-only/read-only mirror、可恢复 journal、冲突副本和逐项删除确认；schema-v5 authorization epoch、records transaction、external-root identity/overlap gate 与 per-record flock 防止重绑、重复授权或撤权后的旧 mirror 提交。所有 provider observation/apply/recovery I/O 都必须先取得有限 hard-accounting grant，并在每次 read/write/commit 前重验 policy、binding 和 authorization；崩溃后的未决 grant 会保守结算。外部目录固定绑定 local-only managed folder，成功 mirror/删除处置会 durable enqueue 精确 rescan；保留 payload 的 recovery summary、retain/dispose、内容围栏临时快照导出 UI 与重启恢复路径已有自动化。导出通过系统分享/“存储到文件”重新选择目的地，不暴露内部 recovery locator，也不改变 retained source；自动原位恢复仍不提供。
- 新用户界面不再把外部目录作为顶层功能，也不在创建/接受 share 时提供不安全的任意 Files 路径绑定。share 固定使用 App-owned managed storage，并在 aggregate Files 位置下显示；只有检测到旧 external authorization record 时，Settings 才显示兼容管理入口，以便审查、恢复或撤销既有授权。
- Designed for iPad 主 App 的 Finder 目录选择仍是主要入口；Mac 专用快捷流程只允许在用户已选择的父目录内创建或复用一个经过严格验证的直接子目录。它不接受绝对路径，不绕过 sandbox，并复用同一 bookmark/probe/broker/binding 链。较早 source-fenced signed My Mac build 已通过，但当前源码未重新签名/launch；bookmark 重启恢复与 mirror 仍未运行，详见[测试矩阵](Docs/TEST_MATRIX.md)。
- 标准 Desktop 互操作已有两组隔离证据：较早 Simulator↔Desktop share 的双向 create/modify/rename/delete 最终 snapshot generation 18、pending bytes 为 0；当前源码上的独立 pinned Syncthing v2.1.3 peer harness 重跑通过 direct TLS/BEP、方向绑定的 upload-only/download-only/index-only（禁止方向零 payload 越界）、双向变更、restart/post-restart transfer、offline conflict-copy 保留、management HTTP disabled 与 sanitized-log gate。显式 `make peer-scale-100k-test` 另以双方 3600 秒重扫和标准 peer 的 production 10 秒 watcher 聚合完成 100 directories / 100,000 physical non-empty files / 8,900,000 bytes 的真实扫描、传输、远端全路径+内容 SHA-256 与整树删除；这仍是 macOS host/pinned-peer 证据，不是签名 iOS 性能或能耗基线。
- BGTaskScheduler 注册/提交状态、轻量本地 refresh、机会性 full-sync processing、App Intents、en/zh-Hans SwiftUI 界面，以及用户主动生成/分享并在结束后清理的 path-free JSON diagnostic summary。
- 用户显式授权的 review notifications：只携带 broad App destination，不包含 path/device/folder/item/recovery identity；durable dispatch tombstone 避免不确定 side effect 被重复调度，点击后必须重新读取 authoritative state。App 与 Intent 的“在文件中打开”使用 stable item ID，并在 URL resolve 前后及交给系统前重验 item/folder/parent/path/type/content/metadata/generation fence。

尚不能描述为产品可用：

- pending acceptance/ignore/unignore 已通过 pinned 标准 peer 的三次真实 offer observation、proof-backed accept、跨 `Core` suppression、CAS unignore 与 re-observation；这仍不是 signed iOS、QR、pending-device 或实体网络证据。固定 Syncthing API 不提供 pending-device 全量查询，因此 bridge 启动前已存在的未知设备需要重连或新事件后才会出现在投影中。
- upload-only、download-only、index-only 已使用 v3 digest 绑定的独立 network session 执行；Swift/Go 对 session、command、query/read、configuration revision、folder 与 byte cap 做精确 scope 校验，App Intent 返回 durable queue/result 的真实结果。它们已有 pinned 标准 peer 自动化，但尚不是 signed iOS/实体网络证据。
- Manual、Glob、Regex、Index Only、On Demand 与 Pinned Offline 的 retention 后端、App/Intent 操作和后台重试已接线，但仍缺标准 peer/签名真机 Files 的完整端到端矩阵。
- iOS 没有公开的“永不回收”per-item content-policy；App 的 Keep Downloaded 是 durable intent、主动 `requestDownload` 与缓存丢失后的重试，不能描述成系统缓存绝不回收。
- system eviction 与 materialized-set reconciliation 已接线，但没有签名真机 Files domain 上的成功/拒绝证据；目录按 Apple 的部分成功边界逐文件处理，不直接调用递归 eviction。
- File Provider working-set signal 会先持久化最大 snapshot generation，并在 domain 安装/App 前台、BG processing 完成和 App Intent 成功时重试；但没有项目控制的 push，App 挂起期间不承诺远端变化实时出现。core network session 会按 native protocol received+sent bytes 硬计量，external mirror 按 logical provider bytes 硬计量，并执行 per-run/每日 expensive cap；运行中策略变化会触发 cancel/drain。仍缺的是实体网络/电源切换、系统调度和完整 kill/recovery/fault-injection 证据，协议 overhead 也不能被描述为某个文件的精确 payload 上传或下载字节。
- 较早的 Simulator Files 检查点使用 aggregate virtual root，并在 share folder 内完成 create/modify/rename/subfolder move/file delete/directory delete 后写回 Desktop。当前 `t` 已重新以真实 Files UI 证明 aggregate 根的两条 share entry，以及 folder create/rename 的 durable completed 结果；delete、普通文件内容 modify、peer 传播、remote-placeholder materialization、成功 eviction 与 kill/retry 仍缺当前系统证据。
- 当前 aggregate 源码已使用 Team `TEAMID0000` 的 Apple Development identity 完成 app/extension 签名，并覆盖安装/启动到 `t` 与 iPad Pro。`t` 的两个正式 AppModel share 已迁移为一个 provider location 下两个 share folders；root capability 与 canonical bridge parent 修复后的 `Final-create` 可打开，create/rename 两条运行历史完成且无网络流量。iPad 同 build 已就绪但尚未人工复验；iCloud Drive/SMB/第三方 provider 仍待证明。

## 环境

- macOS 与 Xcode。当前记录环境为 Xcode 26.6、iPhoneSimulator 26.5 SDK；部署目标仍是 iOS/iPadOS 17.0。Apple 芯片 Mac 使用 Xcode 的 `platform=macOS,name=My Mac` Designed-for-iPad destination，不是 Catalyst 或 Intel target。
- Go 1.25 或更高版本。
- 首次 bootstrap 可访问 Go module source；精确版本和 replacements 由 `GoCore/go.mod`、`GoCore/go.sum` 固定。
- 本机当前签名检查点使用 Team `TEAMID0000`、Apple Development identity `<redacted> (CERTID0000)`、app `moe.simon3k.Psynguechthyngue`、extension `moe.simon3k.Psynguechthyngue.FileProvider` 和 App Group `group.moe.simon3k.Psynguechthyngue`。`CERTID0000` 是该签名身份显示的成员标识，不是 Team ID。当前 Debug candidate 已在 `t` 与 iPad Pro 完成实体安装、前台启动和 identity/config bootstrap；当前脏 worktree 的 Distribution archive/export 已通过，最终 release 仍需冻结 release commit，并完成 extension、Files、peer 与系统生命周期验证。

## Bootstrap 与验证

从仓库根目录执行：

```sh
make bootstrap
make verify
```

`make bootstrap` 与 Xcode Release/CI 仍每次从当前 source 在独立临时位置完整构建被 Git 忽略的 `Artifacts/Mobilebridge.xcframework`，生成机器可读 provenance sidecar，全部验证通过后再成对安全替换旧产物。Xcode Debug build phase 每次仍会运行，但先执行 `--reuse-verified`：只有 source/build-input hash、Go/Xcode/SDK 工具版本、module pins、deployment target、完整 artifact tree、两个 slice SHA-256/architectures 与单返回 bridge ABI 全部匹配时才复用现有 pair；任一不匹配会自动回退到同一 fresh builder。这样 Swift-only Debug 构建不再反复下载 Go modules，发布门禁仍保持全量隔离重建。详见 [XCFramework provenance 门禁](Docs/XCFRAMEWORK_PROVENANCE.md)。

网络不可用但已有完整 Go download cache 时，可把该 cache 的 `cache/download` 目录作为显式只读传输源；它还必须包含 Go 缓存的 signed `sum.golang.org` lookup/tile tree。builder 仍创建全新的 `GOMODCACHE`，仓库 module graph 由 `go.sum`/`go mod verify` 校验，gomobile 临时 module 额外读取的 metadata 则通过本地 file-backed checksum database 验签，且绝不复用历史 build cache：

```sh
PSY_GO_MODULE_PROXY_DIR="$(go env GOMODCACHE)/cache/download" make bootstrap
```

该路径必须是 absolute canonical real directory，且内部只能包含 regular files/real directories；symlink、special node 或缺失的 signed checksum tree 会在进入内部 builder 前失败。module proxy 与 checksum database 都只通过 `file://` 读取，因此不会回退到网络。该缓存不是项目输入或依赖 pin，不能替代缺失的 module，也不会被写入 provenance sidecar。

当前重建缓存的 sidecar 记录 source SHA-256 `a468ef729489946e3c06a27846e6d07248b93bc7da93408005c1e18129cb3258`、artifact tree SHA-256 `fa805b0eb000ab9e7a89bec9c98e1869dce94efab28acba53223d197c909ba49` 与 bridge header SHA-256 `1e2d75028a7e709dda922e1634e8704d443faa3daf2cc8fbc63721c071a82e23`；device/simulator slice 分别为 `78ea550f1db6c44d871111252927e81a246869145c5dc951f857c130850e838a` 与 `813182a469df8457e26145112d9e8fcade24cbc218ef9be9d5434387abd216ee`。它是本地可重建缓存，不是 release archive。

`make verify` 当前依次执行：

- generator-authoritative project 全量成员、plist/version、entitlement、scheme 与配置静态检查；
- SwiftPM tests；
- `go mod verify`、Go tests/vet、完整 mobilebridge race，以及只允许已知 download-only checksum 严格超集的 module-tidiness gate；
- pinned standard Syncthing peer interop；
- notices、许可证 pins 与确定性 SPDX inventory 检查；
- 在最新 available iOS runtime 上创建用后精确删除的临时 iPhone 与 iPad Simulator；每台 fresh device 都先卸载固定测试 bundle并确认 app/appex 容器不存在，把 clean-install contract 作为 build-for-testing 后在该设备上的第一个 product 执行动作，随后运行 en/zh-Hans UI smoke，最后才在临时 iPhone 上实际执行一次 iOS unit target。五个 `test-without-building` 动作各写唯一 xcresult；机器摘要要求 clean/localized UI 分别精确执行 1/2 项，unit 精确匹配已冻结真实计数，且所有动作均为全过、零失败、零跳过、零 expected failure。门禁不会 erase 或复用用户已有 simulator。
- app 和 embedded File Provider 的 Debug generic iOS Simulator 与 unsigned Release generic iPhoneOS builds，并检查各自实际 Mobilebridge slice、`_MobilebridgeNewCore` 在实际 code link image 中是强 external text `T` 定义、app/appex launcher 与可能的 debug dylib 都没有动态 `Mobilebridge.framework` load、实际 code image 存在 libresolv 链接，以及 `1.0.0 (1)` built Info；该最后一次 artifact 写入后紧接完整 provenance/tamper gate，最终 sidecar 对应门禁结束时的产物。

2026-08-22 当前代码审查检查点在真实 `filecoordinationd` 环境完成 SwiftPM **621/621**、strict format 和 unsigned generic iOS Simulator app+extension build。新增回归覆盖 extension 维护任务取消、native materialization 取消、两份内容磁盘预算、Unicode/BINARY 分页顺序、derived-index 恢复备份清理、canonical snapshot 授权与 Intent fallback。此前完整项目、Go、licenses/source-bundle、签名 device build 及 `t` 上 **561/561** 的证据仍分别保留，但本轮按用户要求未进行真机测试。2026-08-21 的 `final3` archive/IPA 早于本轮修复，只能作为历史工程可行性证据；当前源码尚未重新归档，冻结 release commit 也尚未生成。

较早的产品源码索引曾导出到仓库父目录之外的独立源码树，并通过 project-local `.swift-format`、strict format、SwiftPM **568/568**、Go source-lock/full/vet/race/tidy 与 licenses/SBOM/source-bundle 门禁，证明验证不依赖开发者父目录中的格式配置或未纳入 Git 的产品文件。本轮 builder/门禁与文档变更会在最终检查后重新加入暂存索引；尚未生成 release commit，也不会以 unsigned commit 代替最终 release 输入冻结。

可以单独运行：

```sh
make sanity
make format-check
make swift-test
make scale-test
make go-verify
make peer-interop
make peer-scale-test
make licenses
make ios-build
make ui-test
```

构建缓存默认写入 `.build/verify`；每次 iOS build/test gate 都会在其下用 `mktemp` 分配全新的 DerivedData run 子目录，只在同一次 build-for-testing/test-without-building 矩阵内复用该新目录，不能消费上一次运行的 compiled/link products。每次 test gate 还会分配独立结果目录，拒绝覆盖并保存五个 xcresult 供摘要门禁和发布证据使用。需要把整组缓存隔离到别处时可设置：

```sh
PSY_VERIFY_BUILD_ROOT=/private/tmp/psy-verify make verify
```

这些命令不会签名、安装 App 或创建真实 File Provider domain，也不证明真机 Files、后台调度或蜂窝/电源状态。`make peer-interop` 只证明本机隔离环境中、随 App 发布的 latest stable pinned standard Desktop peer；`make peer-scale-test` 另对同一 release 运行 10,000 个实体小文件的全路径+内容摘要与删除门禁。升级 embedded core 时必须更新唯一 release/commit/module pin 并重跑。两者都不证明实体 iOS/Android、relay 或真实 LAN/WAN 生命周期。

## Xcode 与签名真机构建

1. 运行 `make bootstrap`。
2. 将 `Config/Local.xcconfig.example` 复制为被忽略的 `Config/Local.xcconfig`。
3. 填写自己的 `DEVELOPMENT_TEAM`、app/extension bundle identifiers 和 App Group identifier；不要提交个人 Team 或 provisioning 数据。
4. 在 Xcode 打开 `Psynguechthyngue.xcodeproj`，核对两个 target 的签名、App Group、Keychain access group、File Provider 与 Background Modes entitlement，再选择设备构建。

一次签名 build 或 install 不是功能验收；请按[测试矩阵](Docs/TEST_MATRIX.md)记录设备、OS、peer/provider 版本、步骤和结果。

## 文档

- [实现状态](Docs/IMPLEMENTATION_STATUS.md)
- [架构与 ADR 索引](Docs/ARCHITECTURE.md)
- [隐私与安全模型](Docs/PRIVACY_SECURITY.md)
- [真机、互操作与系统集成测试矩阵](Docs/TEST_MATRIX.md)
- [签名、TestFlight 与 App Store 发布清单](Docs/RELEASE_CHECKLIST.md)
- [许可证边界与 MPL source availability](Docs/LICENSE_AND_SOURCE.md)
- [第三方通知](THIRD_PARTY_NOTICES.md)
- [NOTICE](NOTICE)

## 许可证、来源与商标

嵌入的 Syncthing 固定到 commit [`946e2b83a1f6c6ae119427c09e0a5802940b82ff`](https://github.com/syncthing/syncthing/tree/946e2b83a1f6c6ae119427c09e0a5802940b82ff)。[受控许可证映射](Docs/DEPENDENCY_LICENSE_MAP.json)与 [SPDX SBOM](Docs/SBOM.spdx.json)当前覆盖 46 个 production-reachable Go modules；`make licenses` 会 fail closed 验证 module/version/replace、LICENSE/NOTICE/PATENTS hashes、notices、SBOM 漂移与确定性 source bundle。`make source-bundle SOURCE_VERSION=...` 为所有依赖收集精确 recipient files，并为 Syncthing 和 `golang-lru/v2` 两个 MPL-2.0 modules 收集完整对应源码。

发布 binary 前仍必须发布项目控制的 release-specific source archive 和 notices，再用 `make release-licenses SOURCE_OFFER=/absolute/path/to/source-offer.json` 从公开 HTTPS URL 重新下载并核验；自动工程证据不替代发布人或法律复核，详见[许可证与来源门禁](Docs/LICENSE_AND_SOURCE.md)。

原创 Swift、Go bridge、脚本、测试、文档与项目 artwork 由仓库根 [MIT LICENSE](LICENSE) 覆盖；这不会把 Syncthing 或其他第三方组件重新许可为 MIT。

Psynguechthyngue 是独立、非官方客户端，与 Syncthing 项目没有隶属、赞助或背书关系。“Syncthing”仅用于说明兼容目标和所嵌入软件；项目不使用 Syncthing logo。
