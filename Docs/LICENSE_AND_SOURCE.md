# 许可证边界与来源提供

这是工程合规清单，不是法律意见。

## 边界

| 范围 | 许可 |
| --- | --- |
| Psynguechthyngue 原创代码、脚本、文档与 artwork | 根 `LICENSE`（MIT） |
| Syncthing v2.1.6（未修改，无补丁） | MPL-2.0 |
| 其他链接进 `GoBridge/psybridge` 的 Go module | 各自的许可证，见 `THIRD_PARTY_NOTICES.md` |
| Apple SDK / 系统 framework | 由 Xcode/系统提供，不列为第三方包 |

MIT 授权不会重新许可 Syncthing 或任何第三方组件。本项目是独立的非官方客户端，不使用 Syncthing logo。

## Syncthing 精确来源

固定在 `GoBridge/SyncthingPin.json`：tag `v2.1.6`，commit `4461a1ce354d3990660966ad70176e00246adb61`，
module 版本 `v1.30.0-rc.1.0.20261005040355-4461a1ce354d`。上游源码：
<https://github.com/syncthing/syncthing/tree/4461a1ce354d3990660966ad70176e00246adb61>。
`patches` 为空：本项目不修改任何 Syncthing 文件。

## 生成流程

清单 = 以 `GOOS=ios GOARCH=arm64 CGO_ENABLED=1 -tags noassets` 实际链接进 `GoBridge/psybridge` 的 Go module（不含主 module 与标准库）。

```sh
bash Scripts/generate-sbom.sh                 # -> Docs/SBOM.spdx.json (SPDX 2.3，确定性)
bash Scripts/generate-third-party-notices.sh  # -> THIRD_PARTY_NOTICES.md（含完整许可证文本）
bash Scripts/check-licenses.sh                # 校验两者未过期、每个 module 都识别到许可证、NOTICE 含免责声明与 pin 的 commit
```

实现是 `Tools/licenses.py`（`python3 -I` 运行），许可证由 module cache 中的 LICENSE/COPYING 文件识别；
无法识别的 module 会使检查失败。`NOTICE` 手工维护。更新 Syncthing 版本后需更新 `NOTICE` 中的 tag/commit 并重新生成。

## MPL-2.0 源码义务

分发 executable form（TestFlight / App Store 二进制）时：

1. Syncthing 以及任何其他 MPL-2.0 module（如 `hashicorp/golang-lru/v2`）的 covered source 必须可获得，并告知接收者如何取得（MPL-2.0 §3.2）。
2. 因为 Syncthing 未修改，指向上游精确 commit 即为对应源码；发布前建议在项目控制的位置另存一份该 commit 的源码归档作为长期副本。
3. 不得移除或改动许可证声明（§3.4）；不授予商标/logo 权利（§2.3）。
4. app 内应可见 `NOTICE` 与 `THIRD_PARTY_NOTICES.md`。
