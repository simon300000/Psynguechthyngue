# 架构

2026-10-19 重构说明：前台生命周期、应用服务与交互流程已重构，详见 [重构检查](REFACTOR_REVIEW.md)。下列旧检查点保留为历史证据，不能作为本次候选的验收结果。

状态：当前实现与尚未验收边界

最低系统：iOS/iPadOS 17

平台资料复核：2026-08-09，Xcode 26.6 / iPhoneOS 26.5 SDK

## 事实边界

GoCore 不是 lifecycle-only mock：当前 bridge 启动真实 Syncthing app/DB/connection services，并提供配置 CRUD、分页索引/event、文件 CRUD、范围读取和有界 sync。Swift adapter、App、BGTask、App Intents 与 File Provider 都走同一个 runtime/owner 路径。

这些源码与自动化证据仍不等于发布完成。较早 Simulator 检查点曾与标准 Desktop 完成隔离双向同步和 File Provider folder 内实际写回；当前源码的宿主 SwiftPM 619/619、Go full/race/vet、pinned peer interop、fresh Mobilebridge provenance、项目一致性与许可证/source-bundle 门禁通过。iOS unit target 已改为 App-hosted，binary 精确包含 561 个入口，并在 `t` 单次 561/561。Apple Development build 已在 `t` 与 iPad Pro 安装/启动；`t` 证明 aggregate per-share Files root、本地 mutation→Desktop 传播、remote placeholder 打开、custom Keep/Remove、system eviction 与再次打开，iPad 对称 Files 路径按批准豁免。Apple silicon Mac 的主 App明确采用 Designed for iPad 而非 Catalyst。仍未运行的是完整内容 modify/move/delete、长期 extension/resource、自然 BGTask、外部 providers 与冻结发布重放。Android peer 留待 v1.0 之后。详细检查点见 [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md)。

## 核心原则

1. **只有 owner 打开 Syncthing core/DB。** App Group 只提供共享文件系统，不提供并发安全；每个入口必须取得 OS lock 和有效 owner epoch。
2. **Apple 系统拥有 Files replica。** Replicated File Provider 交付 metadata/content，不把 App Group 的 Syncthing root 冒充为 Files 本地副本。
3. **所有入口调用同一策略。** 主 App、BGTask、File Provider 与 App Intents 不各自解释 network/power/delete 规则。
4. **扩展不依赖 App 常驻。** File Provider callback 自行尝试有限时长的 ownership、core work 和 durable result；不能只排队后无条件返回成功。
5. **外部 provider 默认受控镜像。** Go core 只访问 App 管理的 root；外部 URL 始终经 security scope 和 `NSFileCoordinator`。product UI 不开放 direct root。
6. **操作语义显式分离。** Files delete 会传播；system cache eviction 不传播；materialization 只取得当前内容；Keep Downloaded 是 App 的 durable retention intent，不冒充 iOS 不提供的不可回收缓存保证。
7. **崩溃后宁可停住也不重复 mutation。** requestID、digest、owner fencing、base versions 和两层 durable journal 共同决定是否可重试。
8. **共享状态可审计且最小化。** snapshot、result、history 和 external record 使用 stable IDs/code，不写 identity private key、任意 provider error 或已解析绝对外部路径。
9. **上游 watcher 不参与 embedded 并发。** 当前 pinned core 的 folder filesystem watcher 在配置边界强制关闭；所有 App 管理的本地 mutation、external mirror 与 policy change 通过 durable exact-folder rescan 更新索引。

## 进程与数据流

```text
SwiftUI / App Intent / BGTask / File Provider callback
                      |
                      v
            SyncPolicyEngine gate
                      |
                      v
       Swift durable command/result queue
                      |
           flock + owner epoch/fencing
                      |
                      v
          MobileSyncthingCoreClient
                      |
    single-return gomobile JSON/value boundary
                      |
                      v
       Go write-ahead command ledger
                      |
                      v
         embedded Syncthing app + DB
                      |
             snapshot/query/readRange
                      |
                      v
 shared JSON snapshot -> SQLite projection -> UI / Files enumerator
```

外部目录走另一条内容路径：

```text
security-scoped external URL
        <-> NSFileCoordinator
        <-> ControlledMirror manifest/journal
        <-> ManagedFolders/External/<opaque UUID>
        <-> locally configured Syncthing folder
```

## 已验证运行检查点

- 较早 Simulator 与标准 Desktop 的隔离 share 完成双向 create/modify/rename/delete；最终 snapshot generation 18、两设备 connected、folder unpaused、pending bytes 为 0。当前源码的 pinned peer harness 另在连续门禁中通过。
- 当前源码只以 App 固定发布的最新正式 Syncthing `v2.1.3` / `946e2b83…` 经 direct localhost TLS/BEP 完成 upload-only local→peer、download-only peer→local、index-only 双侧零 payload 越界；随后完成双向内容、modify/rename/delete、restart/stable identities、post-restart transfer、offline conflict-copy 两版本保留。显式 100k 门禁以双方 3600 秒重扫和标准 peer production 10 秒 watcher 聚合完成 100 directories / 100,000 physical non-empty files / 8,900,000 bytes 的全路径+内容 SHA-256 与整树删除；传输加全量核验为 1h25m28.159s，完整 package 为 2h19m1.295s。该 release 还完成 2,148,532,224-byte sparse content 的远端 logical size/markers/hole，以及同尺寸 AES-CTR 确定性顺序写满的 non-sparse content 远端全文件 SHA-256；两条路径均验证删除传播。discovery/relay/crash reporting/upgrade/GUI HTTP 均关闭，sanitized-log gate 通过。
- latest-release standard peer harness 先证明错误配置的 Device ID 不接受实际 peer TLS certificate identity，只生成 unverified/explicit-acceptance pending device；用 exact `offerVersion` 接受真实 ID、再配置用户控制的地址后才重连。每轮随后完成三次 pending-folder observation，每次 native limit 为 8 MiB，重复运行实际使用 241–245 B 且未耗尽。offer A 经 live proof 与 configuration revision/offering device/offerVersion 绑定后 accept，proof 被消费；offer B ignore 后跨 `Core` 重建仍保持 suppression，再以 `suppressionVersion` CAS unignore 并重新观察。certificate-matched 隔离 peer 另证明 legacy/unknown hello、oversized hello 与 malformed BEP header 都会断开且不停止 core。升级 embedded core 时必须更新唯一 latest stable release/commit/module pin 并重跑，不维护旧版或预发布版兼容矩阵。
- 较早 Simulator File Provider domain 检查点完成 Files root/working-set path、Desktop→Files exact read 与 folder 内 create/modify/rename/subfolder move/file/directory delete 写回，最终 cleanup generation 39。当前 `t` aggregate 架构另完成目录/普通文件 create、Desktop propagation、remote placeholder 打开、Keep/Remove Download、成功 system eviction、恢复 placeholder 与再次打开；尚未覆盖完整 modify/move/delete、严格 dataless managed-root 取回和长期 kill/resource 生命周期。
- 当前 Team `TEAMID0000` 的 Apple Development app/appex（签名显示成员标识 `CERTID0000`）已在 `t` 与 iPad Pro 完成 install/foreground launch。两台设备均证明 App Group trusted anchor traversal 通过，iPad snapshot 为 schema 1 / generation 2 且 configuration revision 与 local Device ID 存在；`t` UI 显示 Ready、二维码及 Device ID 复制/分享入口。该证据只覆盖主 App identity/config bootstrap，不证明 app↔extension Keychain、Files、peer 或后台。
- 主 App generator/project 显式允许 Designed for iPad，My Mac destination 使用 iPhoneOS/arm64；较早 source-fenced signed build 的 app/appex signing/entitlements/profile、arm64/iPad family/Mobilebridge 检查通过。当前源码未重新签名/launch，Finder/named-child 与 child bookmark quit/relaunch 未运行，不能替代 iPhone/iPad 真机证据。

这些是分开的检查点，不构成同一个 release candidate 的真机验收。

## 进程角色

- **主 App**：SwiftUI、QR、权限请求、设备/文件夹配置、本机保留策略、外部目录、手动 sync、Show in Files 与逐文件 evict；有机会时成为 core owner。
- **File Provider extension**：从 durable snapshot/SQLite 枚举；materialize remote-only item；将 Files create/modify/move/delete 转成真实 bridge command；不得假设主 App 运行。
- **BGTask host**：refresh 只验证本地 snapshot；processing 在系统给定窗口内执行 policy-checked full sync 和有限数量 mirror。
- **App Intents**：只读查询使用 snapshot/SQLite；mutation 通过 durable queue 和 runtime；结果区分 complete/retryable/blocked/failed/unavailable。
- **Go core owner**：动态角色而非常驻 daemon。Swift lease 与 Syncthing 自身 data-dir lock 都成功后才能打开 core。

## App Group 布局

当前 `SharedContainerPaths` 与 Go bridge 使用以下边界：

```text
Coordination/
  syncthing-core.lock
  syncthing-core.lock.owner.json
  syncthing-core.lock.owner.json.fence.lock
  Commands/
    pending/ completed/ results/ locks/ queue.lock
Core/
  Config/                  Syncthing configuration
  Data/                    Syncthing database
  Bridge/
    command-ledger-v1.json
    item-identifiers-v1.json
    pending-devices-v1.json
FileProvider/
  Staging/<command UUID>/
ManagedFolders/
  Folders/<encoded folder ID>/
  External/<opaque UUID>/
Metadata/
  core-snapshot.json
  global-index.sqlite
  global-index-status.json
  file-provider-working-set-signal.json
  sync-policy.json
  run-history.jsonl
  background-task-schedule-status.json
  external-directories.json
  MirrorRuns/<external record UUID>.lock
  content-retention-v1.json
  content-retention-v1.json.lock
```

约束：

- `Core/Config`、`Core/Data` 和 `Core/Bridge` 只由当前 owner 的 bridge 使用。
- `Metadata/global-index.sqlite` 是可重建投影，不是 Syncthing DB。Writer 使用 WAL；UI/extension 只读，generation 必须与 canonical snapshot 对齐。
- `ManagedFolders` 是用户 payload root，与 core config/data 分离；所有 child 名称由 stable ID 或 opaque UUID 生成并做 symlink/containment 检查。
- File Provider command 不接受任意 App Group absolute staging path，只接受 UUID token；Go 重新解析并拒绝越界/symlink。
- external-directory records 当前为 schema v5，保存 monotonic authorization epoch/revision；legacy resolved absolute path 只解码迁移，不再编码。
- app/appex 签名后的 App Group/Keychain entitlement 值、实体安装与被动前台启动已核对；设备首次解锁前的 file protection 和实际跨进程 Keychain/App Group access 尚需真实 command/extension runtime 验证。

## 单 owner 与 fencing

`CoreProcessCoordinator.acquire` 先以 no-follow/regular-file checks 打开 `syncthing-core.lock` 并执行 nonblocking `flock`，再在独立 fencing lock 内读取 owner metadata、严格校验 schema/epoch，并写入 `epoch + 1`、随机 instanceID、role 和时间。symlink parent/leaf、corrupt/missing-after-acquire/zero/overflow 都 fail closed，不把 epoch 静默重置为 1。

Snapshot、command result、queue acknowledgement 和 SQLite projection 周围会重复校验 lease。旧 owner 即使持有过期内存对象，也不能覆盖新 epoch 的 snapshot/result 或确认命令。Go start 还取得 Syncthing data-dir process lock；Swift stop/drain 完成后才释放外层 owner lock。

本机内容保留意图由独立 `ContentRetentionStore` 管理。App、File Provider、BGTask 与 App Intents 通过同一 no-follow lock 和原子文件提交修改 pinned、pending eviction、规则 generation、单文件 eviction transaction 与分页目录 eviction cursor；它既不打开 Syncthing DB，也不读取或写入 `.stignore`。folder incarnation 变化会在同一锁内丢弃旧生命周期意图。

当前自动化覆盖竞争、stale owner、corrupt schema、epoch overflow 和 drain ordering；尚缺签名多进程 kill/reboot/首次解锁故障注入。

## 命令提交、重放与 acknowledgement

1. 入口用稳定 UUID 写 Swift pending queue；同一 ID 不同语义是 collision。
2. Runtime 按命令的 exact session operation 评估策略，不会把 full sync 偷换成单方向。File Provider create/modify/move/delete 例外地使用无网络动作的 `localMutation`：它与 deterministic upload 以一个 atomic batch 入队，本地 mutation 先在 zero-byte、远端全暂停且连接服务关闭的 session 中提交；upload 在网络策略允许时另行运行。
3. Owner 启动 core，把 UUID 作为 bridge requestID。Go 对 canonical request 做 SHA-256，并在 mutation 前把 pending digest 原子写入 0600 ledger、fsync file/rename/directory。
4. Go 执行命令并把完整 success/failure envelope 持久化为 completed。相同 digest 的 completed response 精确回放；不同 digest 返回 conflict。
5. Swift 获取新 snapshot、写 canonical snapshot + SQLite projection、记录 fenced result，再把 pending command 移入 completed。
6. 只有 shared queue 已有 durable completed proof 后，Swift 才调用 `AcknowledgeCommand` 删除 Go entry；owner 启动也会扫描历史 completed 做清理。

崩溃语义：

- completed success/failure：精确回放，不重复 mutation。
- pending `ping/start/stop/rescan/sync`：这些命令被明确列为 replay-safe；先重新持久化 pending，再允许重试。
- 其他 pending mutation：返回 `indeterminate_prior_attempt`，保留 ledger；绝不盲目重放原 mutation。对 File Provider mutation，Swift 会另发 deterministic、owner-epoch-fenced rescan，并以 authoritative snapshot、stable ID/tombstone、no-follow filesystem state 和 retained staging digest 证明目标状态；证明不足时仍保持 failed。
- ledger pre-write 失败：operation 未开始；completion write 失败：entry 保持 pending。
- full ledger 不驱逐旧 requestID。必须由 shared completion proof 驱动 acknowledgement。

Swift result 的 retryable 保留在 pending；blocked/failed 记录后退出 pending，且不会饿死后续合法命令。稳定 error code 会持久化，原始 `localizedDescription` 不进入 result/history。

## Go bridge 边界

Bridge API 只导出 package-owned `Core`、String、Data、Bool 和窄 lifecycle errors；Syncthing internal Go types 不跨边界。

- `SnapshotJSON`、`CommandJSON`、`QueryJSON`、`ReadRangeJSON` 与 `AcknowledgeCommand` 都返回单个 String envelope。
- `CoreRevision`、`DeviceID`、`IdentityBlob` 也为单返回；`RequestCancel` 为 void。
- 这是针对实际观察到的 arm64 Simulator gomobile multi-result cgo 未对齐崩溃所采用的 ABI 约束；bootstrap 会检查生成 header。
- Swift 校验 schema、requestID、kind、stable error code、IDs、relative paths、versions、generation/change cursor 与分页循环。

当前 command 支持：device/folder add/edit/remove、pending device/folder accept/ignore/unignore、pause/resume、rescan、sync、upload、download、exchangeIndex、exact item `materialize`、durable `pin`、local-only `evict`、file create/modify/move/delete，以及 mutation recovery 的 verified export、exact export cleanup、retained disposal / prepared-or-conflict reviewed disposal。`QueryJSON(query=recoveries)` 只返回 opaque recovery ID、folder/command、relative path、payload kind、digest/bytes/time/status，并以 200 项为页；不暴露 recovery locator、绝对 root 或原 request UUID。native export 在 Go 内解析隐藏 locator，以 descriptor-relative no-follow copy 建立 App-owned snapshot，前后复算 digest/bytes；Swift 只收到由 export ID 推导的 opaque private URL，并在 share 结束或重启扫描后请求 native exact-container cleanup。当前 Go source 的 full test/vet、full mobilebridge race、pinned peer interop、fresh Mobilebridge provenance 与 Swift/iOS 产品分项均已重放；宿主 CoreSimulator 故障仅使聚合 UI 入口不可用，按用户决定不再作为 App v1.0 阻塞。

## Snapshot 与 SQLite projection

Go snapshot 只含小型 device/folder 状态以及 bounded pending/suppressed offers。固定 Syncthing API 没有公开 pending-device query，所以 bridge 订阅 `PendingDevicesChanged`，把最多 512 个 Device ID/清洗 label/时间写入最小 0600 store，并披露 persisted/memory-only/unavailable observation scope；地址不会被保存。pending folders 来自 `Internals.PendingFolders`；ignored device/folder 来自 pinned config 的 ignored observations。四组记录均稳定排序、bounded，并披露 available/truncated。Swift 对每个 folder 用 `QueryJSON(items, scope=global, limit=200, includeDeleted=true)` 取完整分页，比较 upstream generation 与 change cursor；分页期间变化会重启，最多三次。

pending accept 先在 Swift 对当前 offer 和 `offerVersion` 做 exact recheck，Go 在 mutation 前再次验证。ignore/unignore 同样用 exact `offerVersion`/`suppressionVersion` 避免过期操作，并把 suppressed state 投影回 UI。device 只采纳用户复核的 Device ID、本机 label/paused；folder 只创建 App Group managed path，显式 device list 必须包含 offering configured peer。remote path/address 永不采纳；encrypted offer 没有安全密码流程时只展示并禁用。

App 固定发布的最新正式 Syncthing `v2.1.3` / `946e2b83…` peer 已把错误 TLS identity rejection、pending-device accept/reconnect 与 folder offer 的真实流程跑通：错误身份只进入 unverified pending-device，exact `offerVersion` 接受和用户控制地址配置后才连接；每轮三次 observation 均使用 8 MiB native limit，重复运行实际使用 241–245 B 且未耗尽；一条 offer 的 proof-backed accept 消费 proof，另一条 offer 的 ignore 跨 `Core` 重建保持 durable suppression，随后以 `suppressionVersion` CAS unignore 并重新观察。certificate-matched 恶意 peer fixture 对 incompatible hello 与 malformed BEP frame 亦 fail closed。该证据只针对随 App 发布的 latest stable core/release pair，不声明旧版、预发布版或 signed iOS/QR 兼容矩阵。

Swift 将 bridge items 转成 canonical `CoreSnapshot`，随后投影到 SQLite schema v4：

- `items`、`tombstones`、`change_journal` 和 store generation；
- folder/parent/working-set keyset queries；
- FTS5 搜索；已有 FTS schema 会先做 capability probe，运行时缺 FTS5 时读写端重建 derived cache、只读端直接降级，二者均使用 escaped LIKE fallback；
- WAL read-only observers、bounded page sizes、integrity check、旧 schema migration、corrupt DB 先备份再重建；
- change row 保存 previous folder/parent/working-set route，使 move 对旧 container 产生 delete、对新 container 产生 update。

SQLite 是 derived cache；projection 失败会写 path-free degraded status，但不会让已经持久化的 canonical snapshot 或 command success 回退。

## File Provider

采用 `NSFileProviderReplicatedExtension`。2026-08-20 的 `t` 真机证明 iOS 会把同一 extension 的多个 domains 聚合在一个 provider 位置下：侧边栏只有 `Psynguechthyngue`，某个 domain root URL 也会被 `UIApplication.open` 拒绝。因此当前可验收 UX 使用一个 aggregate domain；domain root 按 authoritative snapshot 把每个唯一 Syncthing share 枚举为独立文件夹 entry，Files 真机已同时显示 `1 Files UI` 与 `ifles UI`。share folder item ID 使用 folder ID 的 SHA-256 前缀稳定、不透明地派生；App 先安装 aggregate replacement，再逐个移除旧 `share-v1-*` domains。某个正在被 Files 使用的旧 domain 删除失败只留下精确重试项，不能阻止其他 domain 迁移。重复 folder ID 仍 fail closed。

### 枚举与变化

- aggregate root 的 share entries 来自 compact snapshot；各 share 文件树来自 read-only SQLite，缺失/不一致时 bounded fallback 到 canonical JSON snapshot。folder container、indexed item 与 resolved parent 都携带 exact folder scope；跨 share move/reparent 在副作用前拒绝。旧 per-share domain 路由仅用于迁移期间读取，不是当前用户结构。
- stable item identifier 由 bridge registry 分配，与可变 path 分离；delete/recreate 获得新 ID，rename/move 保留 ID。
- item/content metadata version 不超过 128 bytes；page/sync anchor 编码 generation 与 cursor，过期时返回系统 expired error。
- root、working set、folder root、directory 都有分页；working set 包含全部远端占位文件和虚拟共享根。缓存状态变化为 update，只有真实删除为 delete；共享根命名空间变化使旧 anchor 过期并完整对账。共享 label 通过独立合法化及稳定消歧投影为 filename。
- File Provider 的 compact snapshot 是 canonical 原子文件身份绑定、可丢弃重建的摘要；文件和父关系使用 generation-fenced SQLite 查询，故障时显式读取完整 canonical。分页世代只跟随文件元数据变化。
- snapshot generation 先写入 `WorkingSetSignalStore` 的最大 pending generation，再调用 `signalEnumerator(for: .workingSet)`。ack 只清除已发送 generation，并发更高 generation、domain 缺失/禁用或系统调用失败都会保持 durable intent。App 安装 domain/launch、前台 refresh、BG processing `.completed` 和 App Intent durable success 都是重试机会。replicated extension 只 signal working set，由系统向已 materialize containers 传播变化；没有项目控制 push 时仍不能承诺 App 挂起期间实时更新。

### Materialization

`fetchContents` 在 extension 内安装真实 adapter 并争取 owner。已有本机内容先使用 `localContent` 会话交付：硬网络额度 0、关闭 peers、版本和 hash 校验；缺失才进入网络策略。Runtime 每次读取最多 1 MiB，Go 对 local block 或 remote peer block 做 version/hash 验证。每 chunk 与最终 commit 前重载 policy/system state；Task cancellation 通过 nonisolated handle 调 `RequestCancel`。内容写入同目录 O_EXCL/no-follow temporary file，core drain + lease validation 后用 no-overwrite rename 提交，再交给 Files。

这条链有 Swift/Go 自动化；当前 `t` 已从暴露 folder 打开 Desktop 创建的 cloud placeholder，system eviction 后再次恢复 placeholder 并重新打开精确内容。由于当时 share 选择为 Full/All，managed root 可能已持有 bytes；因此证据边界是 File Provider placeholder→open→evict→placeholder→reopen，不声称严格 dataless managed-root 或纯网络 materialization。

### Files mutation 与 storage action

- create/modify/同 folder rename 或 reparent/delete 使用 deterministic requestID、base versions，并在需要内容 payload 时使用受控 staging；它们运行真实 CoreRuntime，并等待 durable succeeded result + committed snapshot。符合 mutation access 的 item 广告 `allowsReparenting`。terminal/indeterminate mutation 不重放 original UUID；独立 rescan + state proof 成功后才可将原结果提升为 succeeded。
- staging token 只能是 UUID command directory 下的 `contents`。Swift 在跨进程 operation lock 内预留 `2 × source bytes + 256 MiB`，以 no-follow descriptor + inode/size/timestamp recheck 拒绝 symlink、非普通文件和 source swap，使用 0700 directory、0600 file、iOS first-unlock protection 与 SHA-256 幂等校验；age GC 只回收超过 24 小时且不被 pending command 或未决 reconciliation 引用的真实 UUID directory。
- cross-folder move/reparent 在 selection、staging、enqueue 和 native mutation 等副作用前 fail closed，且不广告。Files copy 可能以 destination `createItem` 到达；每个 destination create 独立执行 configuration revision + folder incarnation 双 fence、受控 staging 与 durable result，不声明 source-coupled 原子 copy、copy+delete 或整个目录树的原子性。system callback replay/kill 与异常终止 staging cleanup 仍需设备级扩展。
- delete 参数明确 `propagatesToPeers=true`，Go 通过 Syncthing delete/rescan/index 确认；它与 cache eviction 是不同 operation。
- `IndexedItem.isUploaded` 是 eviction 代码唯一的内容安全资格输入。它只在当前 item/version/size/blocks 已有至少一个非 temporary 远端完整副本且没有更新的本地修改、冲突、删除或 invalid 状态时为 true；本地修改立即清除该值。eviction 自身不重复解析这些条件，系统仍可独立返回 `unsyncedEdits` 等错误。
- `isUploaded=true` 时先持久化 transaction，再调用 system `evictItem`，成功后通过普通 bridge eviction 再次验证远端副本并释放 managed root 内容；`isUploaded=false` 时只清除 pin 并持久化 `pendingEvict`。目录按一致 generation 的完整 metadata index 分页，对每个 materialized 普通文件分别处理，不使用会部分成功的递归目录 eviction。
- extension 通过公开的 `NSFileProviderCustomAction` 和 `NSExtensionFileProviderActions` 在 Files context menu 提供 Keep Downloaded / Remove Downloaded。目录请求先持久化 generation-bound cursor；进程退出后 App/BG 可从 cursor 继续，generation 漂移时从头幂等重算。较新的 Keep Downloaded 会取消未完成目录释放并在已启动的 system eviction 返回后保留 pin。
- iOS 不提供 macOS-only 的 durable keep-downloaded content policy。App 的 Keep Downloaded 是自己的 durable pinned intent：可以主动请求下载并在后台重试，但不承诺系统永不回收。`materializedItemsDidChange` 只报告系统已经发生的缓存变化；extension 先持久化 reconciliation marker，再单独更新 Files replica 集合，不从系统缓存缺席推断 core 文件消失；pinned 项随后重新请求系统副本。pending-item set 只用于补充状态和唤醒，不作为上传或 eviction authority。

较早 Simulator 检查点与当前 aggregate 架构都使用 provider root 下的 share folder entries；只有可写、未暂停且健康的 share folder 声明 `allowsAddingSubItems`。当前 `t` 已以真实 Files UI 证明两个 share entries、目录 create/rename、普通文件 local mutation→Desktop、remote placeholder 打开、Keep/Remove、成功 eviction 与再次打开。删除、内容原位 modify、长期 extension kill/recovery 和资源预算仍待执行。

见 [ADR-0001](ADR/0001-replicated-file-provider.md)、[ADR-0002](ADR/0002-ios-file-provider-pin-evict.md)、[ADR-0008](ADR/0008-file-provider-retention-and-eviction.md) 与 [ADR-0010](ADR/0010-files-metadata-and-content-ownership.md)。

## 本机内容保留系统

`FolderSelectionPlan` 明确区分 Full、Manual、Glob、RE2-safe Regex、Index Only、On Demand 与 Pinned Offline，但这些模式只决定移动设备上哪些 global-index 项目应长期保留下载，不再改变 Syncthing 扫描或 ignore 范围。App 不生成、解析、校验或重写 `.stignore`；用户文件及 core ignore 结果保持权威。

- Full 与 Pinned Offline 对整个 folder 产生 inherited pinned intent。
- Manual 的三态目录 directive 对现有和未来子项求值；Glob/Regex 只对 global-index metadata 求值。规则顺序、include/exclude、generation、预览与 rollback 都保存在 `ContentRetentionStore`，不会被编译为 Syncthing ignore pattern。
- Index Only 只交换 global index 并展示 dataless placeholders；On Demand 在打开时 materialize，下载完成后仍允许自动释放。普通下载不自动 pin。
- selective folder 的普通 `.sync` 只执行 upload/index exchange；精确 pinned 或用户打开的 item 用独立 materialize session 获取当前版本。core 的 ignore 结果始终优先，App 不试图绕过被忽略的项目。

Regex/Glob matcher 使用 bounded Thompson NFA，无 ICU/`NSRegularExpression` 回溯，并对 pattern length、group depth、state/expansion count 设硬上限。目录 pin/unpin 通过 normalized path 继承到未来子项，显式 item intent 优先；stable item ID 使 pending eviction 随 rename 保留，folder incarnation 更换则使旧意图和 transaction 失效。

## 外部目录

用户通过系统 document picker 授权目录。schema-v5 Record 保存 bookmark、display name、capability、mode、opaque managed-root token、binding state、authorization state/epoch、monotonic revision 和 path-free status；legacy absolute resolved path 只解码迁移，不再编码。

Authorization 时：

1. iOS/Designed for iPad 创建 `.minimalBookmark` 并成对使用 security scope；旧 bookmark 继续兼容解析。
2. 通过协调访问 probe enumerate/read/create/write/replace/rename/delete/recursive behavior；read 与完整 CRUD 都只能在系统 coordinator accessor 内执行，回调未执行时 fail closed。
3. 按实测能力单向降级；direct request 也只能变成 controlled mirror/import/read-only。
4. 创建 `ManagedFolders/External/<UUID>`，用保留在 App 管理范围内的 `.stfolder` 标记 mirror internal state；用户 `.stignore` 从不被读取或改写。
5. 以确定性 `external-<UUID>` local-only folder ID 入队 `addFolder`，不自动分享给任何 peer。
6. 只有 latest snapshot 的 folder ID 和 exact managed path 匹配才标记 verified 并允许 copy；missing/mismatch 进入 repair/conflict，不自动重建用户可能故意移除的 folder。

records mutation 使用跨进程 transaction lock，每次在锁内重读并合并 durable set；revocation 先递增 authorization epoch、清除 bookmark/confirmation，旧 broker 不能复活授权。每个 record 的 mirror run 还持有 nonblocking flock，所有 I/O 与 atomic-copy pre-commit 都重验 epoch。

每次新授权先逐 component `O_NOFOLLOW` 捕获 external root 的 device+inode identity；capability probe 后、bookmark create/resolve 前后，以及最终 records transaction 内都会重验原 URL 与 bookmark-resolved URL。transaction 同时拒绝相同、ancestor 或 descendant external roots；进程内 reservation 与跨 broker/process records lock 防止并发重复 record。legacy 数据若已有重叠 active roots，mirror、recovery 与删除确认等所有实际 external I/O 入口统一 fail closed。

在 Apple 芯片 Mac 上，主 App 使用 Designed for iPad。系统 Finder/Open panel 仍是主要授权入口；仅 `isiOSAppOnMac` 显示的快捷流程允许输入一个安全单 component 名称，再在 picker-authorized parent 内创建或复用直接 child。名称拒绝空/点组件/路径分隔/control/超长，创建、复用和 rollback 使用 parent descriptor、no-follow 与父/child inode 重验；新建目录只有仍为原 inode 且为空时才删除。child bound identity 随后交给同一 broker，不把绝对路径直接交给 core。见 [ADR-0007](ADR/0007-designed-for-ipad-on-apple-silicon-mac.md)。

ControlledMirror 扫描两侧 real files/directories并拒绝 symlink、special type、overlapping roots 和 canonical case/Unicode collisions。planned/applying journal 使原子 copy 可从中断续跑；commit 前后会重验 source/destination fingerprints，以 same-volume exclusive/swap rename + fsync 安装，并在失败时 rollback，避免静默覆盖并发修改。双边修改保留 stable conflict artifact。单边缺失只创建 digest-bound confirmation，用户明确选择 keep/restore 或 propagate 后再全量重验 manifest；内容变化时不删除。

每次 mirror copy 或显式 deletion resolution 改变 managed root 后，broker 为经过 exact folderID/path 验证的 local-only binding durable enqueue `.rescan`；失败记录 `rescanQueueFailed`，由前台/BG 的后续队列处理机会重试。它不会把“文件已复制”偷换成“Syncthing index 已更新”。

原子替换保留的 recovery payload 有独立 summary/resolve 路径。broker 在同一 per-record lease、bookmark scope、authorization epoch、binding 与 policy fence 内只向 UI 暴露 relative path、payload kind、bytes/time/status 和 digest prefix；retain 不改 bytes，dispose 需要 exact summary 和显式确认。内容围栏 export 以 no-follow descriptor 建立临时快照并复算 recovery digest，share 结束后精确删除私有 container；retained source 与 live mirror 不变。仍被 planned/applying journal 引用的 payload 不能处置；读取外部 provider recovery payload 前必须满足 download action 和 transfer byte policy。

当前算法、local-only binding、rescan、recovery UI/broker 与 authorization identity/overlap fences 有本地自动化；iCloud Drive、SMB、第三方 provider、bookmark stale/revoked/offline 和 provider move 仍需真机验证。见 [ADR-0003](ADR/0003-external-directory-access.md)。

## 统一策略与后台

`SyncPolicyEngine` 输入 trigger、requested actions、NWPath kind/expensive/constrained、transfer estimate、charging/battery/Low Power/thermal、disk、time window 和 safety state，输出 allowed/blocked actions、stable reason、remedy/override eligibility。

- policy 在 core start 前执行；一般 network session 运行期间约每 100 ms 重读当前环境、策略、configuration revision 与 folder incarnation，materialization 还在每 chunk 与 commit 前重检。
- 运行中撤权会请求 native cancellation，并在 stop/drain 后释放 owner；Go protocol reader/writer 同时执行 finite aggregate byte cap。该边界不是逐 packet 的 Network Extension firewall，也不能把 aggregate protocol bytes 解释为某个文件的精确 upload/download payload。
- upload-only/download-only/index-only 使用 v3 digest 与 `networkOperation` 精确绑定独立 session；有效 Syncthing folder mode、上游 request/requestGlobal payload gate 与 Swift runtime policy 三层同时收窄方向。pinned 标准 peer 已验证禁止方向不传 payload，full sync 不再被用来冒充单方向。
- accurate daily network counter 为 nil 时 daily cap 不执行，Settings 强制保存为 nil；不伪造 0 bytes 已用。
- embedded folder config 强制 `FSWatcherEnabled=false`；受控内容变更和 external mirror success 都显式 rescan。该选择用确定的 scan boundary 换取后台常驻 watcher 的缺失，避免 pinned upstream config-update race。

BGAppRefresh 只读取/验证 durable snapshot 和通知候选，不启动 core。BGProcessing 的 scheduler hint 来自同一 policy 和 pending bytes；只有 upload/download/scan 全允许时提交 exact-folder full-sync work，并可在系统实际授予的机会内轮转执行 bounded pending-folder discovery。Handler 一开始重提下一次机会，expiration 会取消 core/mirror，one-shot gate 保证 `setTaskCompleted` 仅调用一次；注册、submit 与持久状态错误均映射为稳定诊断码。BGTaskScheduler 最终决定是否和何时运行，`earliestBeginDate` 不是预约。

见 [ADR-0004](ADR/0004-background-and-network-policy.md)。

## App Intents 与 UI

Intents 查询 status/why/device/folder/search，不打开第二个 Syncthing DB；sync、direction-bound upload/download/exchange-index、pause/resume/rescan 走同一 queue/runtime/policy。Download、Keep Downloaded、Remove Downloaded 和 Show in Files 都消费真实 stable item/context：前两者持久化 retention 并按策略 materialize，Remove Downloaded 只消费当前 exact `isUploaded` 或建立 `pendingEvict`，Show in Files 使用 source-fenced URL。不存在只返回 unavailable 的伪能力。

SwiftUI 使用五项 `TabView` 组织 Overview、Devices、Folders、Files 和 Settings；iOS 26 iPhone 使用系统 Liquid Glass tab bar，并在向下滚动时最小化，iOS 17–25 回退为普通系统 tab bar。Run History 是 Overview 的下一级页面。新建/接受 share 只使用 App-owned managed storage；旧 external mirror 授权不再出现在顶层或新建流程中，仅当现有记录存在时，Settings 提供兼容管理入口，避免授权与 recovery 数据失去处置路径。其余界面提供 QR 生成/扫描、设备/文件夹表单、global index、选择/规则、context menu、keyboard shortcut、share 和 en/zh-Hans strings。Settings 可生成最大 1 MiB 的 path-free diagnostic JSON summary，并通过系统 share sheet 由用户主动分享；dismiss/complete 后只清理受控 export 文件。已有 Simulator smoke 覆盖两种语言、iPhone/iPad 与 accessibility XXXL launch；VoiceOver 实际朗读、pointer、dark mode、Reduce Motion 和完整 restoration 仍未验收。

## 安全与隐私

- Identity private key 只以 opaque blob 进入 ThisDeviceOnly Keychain；不写 App Group、日志或临时文件。
- Release core 不开放 management HTTP，不启用 usage/crash reporting、analytics 或 auto-upgrade。
- 文件 mutation 校验 relative path、root、symlink、case/Unicode collision、base version 和 atomic replacement；delete/evict/materialize 使用不同 API 和文案。
- 外部 provider NSError、absolute path、bookmark、command arguments 和 private key 不进入 ordinary result/history。Go ledger 只保存 requestID、digest、state 和 exact sanitized envelope。
- diagnostic exporter 不打开 command/result payload，只汇总 allowlisted state/count/code；所有输入有 no-follow/type/size/change bounds，输出使用 0700 directory、0600 O_EXCL file、fsync/no-overwrite commit，并在分享结束后删除。
- App 与 File Provider 各自包含 `PrivacyInfo.xcprivacy` 并进入各自 target resources；两者声明当前 required-reason categories，不能用主 bundle 替 extension。实际 signed archive、第三方聚合与 App Store privacy 仍需 release 审核，见 [ADR-0006](ADR/0006-required-reason-privacy-manifests.md)。

## 尚待架构验收

在描述为可用客户端前，至少还需要：

1. 在实体 iOS release candidate 上补齐 Desktop 的内容原位修改、move/delete、冲突、断网和恢复；当前 `t` 已完成 explicit peer accept/edit、create/write-back→Desktop 与 Desktop placeholder→Files。Android peer 不属于 v1.0 门禁。
2. 签名 app/extension/intent/BGTask 竞争、kill/reboot/首次解锁下的 owner/ledger 恢复。
3. App 不运行时 Files remote fetch、kill/retry、change signaling，以及 24 小时 disk-write/resource 预算；当前短期 smoke 不替代完整真机 extension lifecycle。
4. 在标准 peer/实体 Files 上补齐 Regex、Index Only、On Demand、whole-folder Pinned Offline、目录 cursor 恢复和自动缓存回收后的独立 replica 对账/重下；custom Keep/Remove 与单文件 system eviction 已在 `t` 通过。iOS 不提供不可回收的 per-item content policy；产品只承诺自己的 durable retention intent 与重试。
5. 真机 external providers、网络切换、Low Data/Low Power/thermal、BGTask expiration。
6. 完整 release notices、MPL source availability、archive 与商店审核。

## ADR 索引

- [ADR-0001：Replicated File Provider](ADR/0001-replicated-file-provider.md)
- [ADR-0002：iOS pin、materialize 与 evict](ADR/0002-ios-file-provider-pin-evict.md)
- [ADR-0003：外部目录、bookmark 与 controlled mirror](ADR/0003-external-directory-access.md)
- [ADR-0004：BGTaskScheduler 与统一网络/电源策略](ADR/0004-background-and-network-policy.md)
- [ADR-0005：跨进程单 Syncthing core owner](ADR/0005-single-core-owner.md)
- [ADR-0006：每个可执行 bundle 的 required-reason privacy manifest](ADR/0006-required-reason-privacy-manifests.md)
- [ADR-0007：Apple 芯片 Mac 的 Designed for iPad 运行与 Finder 目录授权](ADR/0007-designed-for-ipad-on-apple-silicon-mac.md)
- [ADR-0008：File Provider 本机保留、上传状态与逐文件释放](ADR/0008-file-provider-retention-and-eviction.md)
