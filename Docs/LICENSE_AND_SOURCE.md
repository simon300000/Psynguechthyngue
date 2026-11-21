# 许可证边界与来源提供

最后复核：2026-08-14

本文把源码归属、二进制依赖和发布门禁分开记录。它是工程合规清单，不是法律意见。

## 当前边界

| 范围 | 当前事实 | 发布含义 |
| --- | --- | --- |
| Psynguechthyngue 原创代码与项目 artwork | 根 `LICENSE` 为 MIT | 原创 Swift、Go bridge、脚本、测试、文档与 artwork 采用 MIT；不会覆盖或重新许可第三方代码 |
| 带文件级 SPDX 的 bridge/scripts | `GoCore/mobilebridge` 与相关脚本中的若干文件声明 `SPDX-License-Identifier: MIT` | 声明只适用于其标注文件，不能据此推断整个仓库或 Syncthing 被重新许可 |
| MPL-covered Go modules | Syncthing 固定到 commit `946e2b83a1f6c6ae119427c09e0a5802940b82ff`；production graph 还包含 MPL-2.0 的 `github.com/hashicorp/golang-lru/v2@v2.0.7` | source bundle 必须包含两个 module cache 的完整对应源码；新增或漂移的 MPL module 会使门禁失败 |
| 其他 Go 依赖 | `Docs/DEPENDENCY_LICENSE_MAP.json` 逐项绑定 production-reachable module/version/replace、SPDX expression 与根 LICENSE/NOTICE/PATENTS SHA-256；`Docs/SBOM.spdx.json` 另保留精确 build list 与 shipped/dev 分类 | 未映射、未知许可证、文件增删/改写、依赖可达性或 source URL 漂移全部 fail closed；工程映射仍不是法律意见 |
| Apple SDK/system frameworks | 由 Xcode/系统提供；项目引用 Foundation、Security、FileProvider 等 | 不把系统 framework 猜列为可再分发第三方包；最终 archive 仍需按 Apple 协议和工具检查 |
| AppIcon/项目视觉资产 | 当前 AppIcon 是原创项目资产，不是 Syncthing artwork | 最终根许可证应明确代码与视觉资产是否采用不同授权 |

## Syncthing 的精确来源

- Bridge 版本标签：`v2.1.3`
- Go module pseudo-version：`v1.30.0-rc.1.0.20260803213605-946e2b83a1f6`
- 精确 commit：`946e2b83a1f6c6ae119427c09e0a5802940b82ff`
- 精确源码：<https://github.com/syncthing/syncthing/tree/946e2b83a1f6c6ae119427c09e0a5802940b82ff>
- 该 commit 的 LICENSE：<https://github.com/syncthing/syncthing/blob/946e2b83a1f6c6ae119427c09e0a5802940b82ff/LICENSE>
- Mozilla 官方 MPL 2.0：<https://www.mozilla.org/en-US/MPL/2.0/>
- Mozilla 官方 FAQ：<https://www.mozilla.org/en-US/MPL/2.0/FAQ/>

截至本次复核，MPL 2.0 第 3.2 节要求在分发 executable form 时，使 covered source code 可获得，并告知接收者如何通过合理方式及时取得；第 3.3 节允许 larger work 使用其他条款，但不免除 covered software 的要求；第 3.4 节限制移除或改动许可证 notices；第 2.3 节不授予商标、服务标记或 logo 权利。发布负责人必须以官方正文和实际修改情况为准。

## 可重复的许可证与源码门禁

- `make licenses`：重新生成并逐字比较 SPDX 2.3 SBOM 和第三方 notices，核对 46 个 production-linked module 的受控映射，运行未知/漂移/路径逃逸/恶意 archive 回归，并把 source bundle 连续生成两次确认逐字节确定性。
- `make source-bundle SOURCE_VERSION=v1.0.0`：生成 release source archive。archive 为所有 production-linked modules 带上精确 LICENSE/NOTICE/PATENTS 文件，并为两个 MPL-2.0 modules 带上完整 module-cache source tree；同时嵌入并逐字绑定项目 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`、许可证映射、SBOM 与本说明。内嵌 manifest 绑定这些发布材料、逐文件和整棵源码树 SHA-256。
- `make release-licenses SOURCE_OFFER=/absolute/path/to/source-offer.json`：只在 clean release checkout 中运行，并在联网校验前后确认 commit/工作树未变化；从 offer 的两个公开 HTTPS URL 重新下载 source archive 和 `THIRD_PARTY_NOTICES.md`，核对 release commit、URL、archive/map/SBOM hash、archive 安全结构、MPL source trees、项目级发布材料与当前 notices。
- `make verify-app-store-export APP_STORE_ARCHIVE=/absolute/path/App.xcarchive APP_STORE_IPA=/absolute/path/App.ipa`：只读解包最终 IPA，拒绝不安全路径，核对 App/extension 的 Store 签名、profiles、entitlements、版本、架构、静态 core revision、privacy manifests、三份法律资源及 archive dSYM UUID。当前脏 worktree 的 `1.0.0 (1)` export 已通过；冻结 release commit 仍须重跑。

`Docs/RELEASE_SOURCE_OFFER.example.json` 只是 schema 示例；其中 placeholder、零 hash 和未发布 URL 会被 production gate 拒绝。常规 CI 运行离线/本地确定性验证，不伪造一个已发布的 source offer。实际 URL 可用性只能在发布后由 `make release-licenses` 联网确认。

## Source offer / source availability 规则

仅链接到当前上游 GitHub 页面不是完整的长期发布方案。每个分发版本在出包前至少要：

1. 从该 release 实际使用的 `go.mod`、`go.sum`、replace directives 与构建参数确定所有 MPL-covered source。
2. 保存精确 Syncthing 与 `github.com/hashicorp/golang-lru/v2` 上游源码，以及该 release 中对 covered files 所做的任何修改；不得只保存补丁而丢失可对应的基线。
3. 在项目控制、可持续访问的位置发布不可变的 source tag/archive，并记录 URL 与 SHA-256。上游 URL继续保留为 provenance，但不作为唯一副本。
4. 在 app 内可发现的 notices、发布页面和随包 NOTICE 中告知接收者如何取得与该二进制对应的源码。
5. 验证下载内容可解包、可对应 binary revision，并包含许可证/notice；由人工复核是否满足 MPL 对 covered source 的实际范围要求。
6. 按适用期限保留 release source、构建记录、依赖清单和通知；具体保留期由法律复核决定，不能在工程文档中猜定。

当前项目控制的持久 source URL 尚未发布，所以任何 TestFlight 或 App Store 二进制分发均为阻塞状态。

## 产物与可复现性

`Artifacts/Mobilebridge.xcframework` 是可生成、被 Git 忽略的本地产物，不是源码交付位置；其 [provenance sidecar](XCFRAMEWORK_PROVENANCE.md) 会 fail closed 校验当前 source/build inputs、tools、pins、artifact tree、ABI 与 slice hashes。`make licenses` 会重新生成并逐字比较 `Docs/SBOM.spdx.json` 与 `THIRD_PARTY_NOTICES.md`，并验证受控 map、所有 recipient files 和 MPL source bundle；依赖图、replace、许可证或文件 hash 漂移都会失败。发布记录必须包含：

- 源仓库 commit、dirty/clean 状态与固定的 Go/Xcode 工具版本；
- `go.mod`、`go.sum` 和所有 replace directives；
- XCFramework 及最终 archive 的 SHA-256；
- device/simulator slices 与链接内容清单；
- 构建脚本和构建日志中的非敏感参数；
- 对应的第三方 inventory、人工审核人/日期与 source URL。

能重新生成相似二进制不替代许可证要求；反过来，提供源码也不证明当前产品构建或互操作已验证。

## 商标与项目身份

Psynguechthyngue 是独立、非官方客户端，与 Syncthing 项目没有隶属、赞助或背书关系。“Syncthing”仅用于准确说明所嵌入软件和兼容目标。项目不使用 Syncthing logo；原创 AppIcon 不能改造成易被误认为官方 Syncthing artwork 的形式。商店名称、关键词、截图和支持页面均须保留这一区分。

## 发布阻塞项

- [x] 权利人已提交覆盖原创项目代码与 artwork 的 MIT 根许可证。
- [x] 生成 production-reachable dependency inventory，并用精确 module/version/replace 与 LICENSE/NOTICE/PATENTS hash 建立受控映射。
- [x] 当前仓库没有 vendor 或直接修改 module cache 内的 MPL files；source bundle 保存当前两个 MPL modules 的完整基线源码，后续 build graph/source 漂移会失败。
- [x] app Settings 已提供可发现的开源声明入口，并把根 `LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md` 逐字打入主 bundle；缺失资源时界面会明确禁止分发。
- [ ] 发布项目控制的、不可变的 release-specific covered-source URL 和校验值。
- [ ] 把 release-specific source 获取方式接入 app 内声明、随包 NOTICE 与发布页，并在冻结 archive 中重新核对三份资源及公开 URL。
- [ ] 对 archive、商店元数据和 source offer 做发布人及法律复核。

未全部关闭前不得分发 TestFlight 或 App Store binary；机器门禁通过不能替代发布人/法律复核或公开 URL 的实际可用性。
