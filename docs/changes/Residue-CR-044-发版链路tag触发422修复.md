# CR-044 · 发版链路 tag 触发的 422 修复接回 main · P2 · 分支卫生

> 状态：已实施
> 变更类型：CI 修复（**不改产品代码、不改契约条文、不改 `T` / 门槛判定 / `Source` 枚举**）
> 影响面：`.github/workflows/release.yml`（`Create GitHub Release` 步骤）；导航项数声明 3 处
> 风险等级：P2 —— 不触碰任何产品不变量。失败模式是「构建、校验、打包、上传全部成功，最后一步建 Release 报 422」，产物本身不受影响

---

## 一、缺陷

`.github/workflows/release.yml` 的 `Create GitHub Release` 步骤把 `GITHUB_REF_NAME` 当 `--target` 传给 `gh release create`：

```bash
TARGET="${GITHUB_REF_NAME}"
if [ "${GITHUB_REF_TYPE}" != "tag" ]; then
  TARGET="main"
fi
gh release create "v${VERSION}" --target "$TARGET" ...
```

tag 触发时 `GITHUB_REF_NAME` 是 **tag 名**（如 `v0.1.5`）。GitHub API 的 `target_commitish` 只接受分支名或 commit SHA，传 tag 名直接被判 422。

实测证据（run `43583551221`，`event=push`，`headBranch=v0.1.5`，2026-11-14）：

```
HTTP 422: Validation Failed (https://api.github.com/repos/gztcode/residue/releases)
Release.target_commitish is invalid
```

同一次 run 的前 12 个 step 全部 `success`（tests / contract / baseline docs / 打包 / a5 / 校验和 / 上传产物），只有 `Create GitHub Release` 为 `failure` —— 也就是说，**校验全绿、包也打出来了，唯独 Release 没建出来**。

## 二、v0.1.5 / v0.1.6 是怎么发出去的

两次都**没有走 tag 触发**，而是手动 `workflow_dispatch`：

| 版本 | run | 触发方式 | headBranch | 结果 |
|---|---|---|---|---|
| v0.1.5 | `43583835464` | `workflow_dispatch` | `gztcode/tiamat` | success |
| v0.1.6 | `44878541585` | `workflow_dispatch` | `main` | success |

dispatch 时 `GITHUB_REF_TYPE` 是 `branch`，脚本把 `TARGET` 改写为 `main`，所以**不经过 422 那条路径**。v0.1.6 的 Release 由该 run 的 `Create GitHub Release` 步骤创建（日志结尾打印 `https://github.com/gztcode/residue/releases/tag/v0.1.6`）。

⇒ 缺陷真实存在，只是被「手动 dispatch」这条旁路绕过去了。修它的意义是让 `git push origin v*` 这条写在一开始的主路径重新可用，而不是每次发版都必须记得手动点 dispatch —— 后者不写下来就一定会忘。

## 三、修法

按触发方式分支，tag 触发不传 `--target`：

```bash
if [ "${GITHUB_REF_TYPE}" = "tag" ]; then
  gh release create "v${VERSION}" \
    --title "Residue v${VERSION}" \
    --notes-file /tmp/notes.md \
    "$DMG" out/SHA256SUMS.txt
else
  gh release create "v${VERSION}" \
    --target "main" \
    --title "Residue v${VERSION}" \
    --notes-file /tmp/notes.md \
    "$DMG" out/SHA256SUMS.txt
fi
```

tag 已经存在，release 直接指向它即可；只有 workflow_dispatch（没有 tag）才需要显式给 `main`。

## 四、为什么不把 tiamat 整体搬过来

分叉现状（实测，不采信文档旧描述）：

```
git rev-list --left-right --count origin/main...origin/gztcode/tiamat
39	2                    # main 独有 39，tiamat 独有 2
git merge-base origin/main origin/gztcode/tiamat
949ad09 Merge pull request #3 from gztcode/gztcode/dmg-i18n
```

tiamat 独有的两个提交：

1. **`56c6f91` `feat(ui): 视觉基线 v2（CR-031）落地，并修复重启后把未知显示为 0（P1）`**
   改动 18 个文件。**main 上不存在，也不是 squash/等价形态**：`ConfirmDrawer.swift` / `EvidencePage.swift` / `MenuBarPopover.swift` / `PolicyPage.swift` / `PrivacyPage.swift` / `ReportPage.swift` 在 main 上全部缺失，`RatioSlot` 零命中，`MenuBarExtra` 仍是 `.menu` 而非 `.window`；`git cherry origin/main origin/gztcode/tiamat` 把两者都标为 `+`（未吸收）。另外它把 **CR-031 这个编号用在了「视觉基线 v2」上**，而 main 的 CR-031 是「KJ 结算写入」—— 直接搬会制造两个 CR-031。
2. **`54ac2ba` `ci(release): tag 触发时不再给 gh release 传 --target`**
   本单**只取其中的 `--target` 分支逻辑**。

`54ac2ba` 里还夹带了两样东西，**不能一起搬**：

- release notes 的计数更新（`283 → 304` 单测、`72 → 86` 页面结构）—— main 当前已是 **575 单测 / 80 页面结构 / 117 接线 / 43 产物**，cherry-pick 会把计数改回旧值；
- v0.1.5 的更新内容 —— 与当前版本无关。

所以本单是**重做**而非 cherry-pick：只改 `--target` 这一段，其它一行不动。

## 五、落点穷举表

| 文件 | 旧 | 新 |
|---|---|---|
| `.github/workflows/release.yml:217-227` | `TARGET="${GITHUB_REF_NAME}"` + 无条件 `--target "$TARGET"` | tag 分支不带 `--target`，非 tag 分支带 `--target main` |
| `CLAUDE.md:11` | `docs/` 下 146 份 | 147 份 |
| `CLAUDE.md:133` | `docs/` 下 146 份 | 147 份 |
| `ARCHITECTURE.md:87` | 66 份文件 / 28 个单号 | 68 份文件 / 30 个单号 |
| `tests/contract/fixtures/doc_claims.json`（`docs_md` 的 `declared`） | 146 | 147 |

`ARCHITECTURE.md:87` 的旧值（66 / 28）在本单之前就已经落后于实测（67 / 29，CR-040 / CR-041 落地后未同步）；本单顺带把它对到加单后的实测值。

## 六、单测与产品代码

**产品代码零改动**，因此单测数保持 **575**、`verify_a9.sh` 80 项、`--verify-wiring` 117 项、`verify_a5.sh` 43 项（6 项如实标未覆盖）、PRD 238（191 + 47）、R2 123 均不变。`ci.yml` / `release.yml` 里的单测声明行**未改**。

## 七、验收

| 命令 | 预期 | 实测 |
|---|---|---|
| `swift build` | 成功 | ✅ Build complete（exit 0） |
| `swift test` | 575 / 0 failures | ✅ Executed 575 tests, with 0 failures |
| `python3 scripts/verify_codes.py` | 11 / 0 | ✅ 通过 11 项 / 失败 0 项 |
| `./scripts/verify_a9.sh` | 80 / 0 | ✅ 通过 80 项 / 失败 0 项 |
| `swift run --disable-sandbox ResidueApp --verify-wiring /tmp/wiring` | 117 / 0 | ✅ 通过 117 项 / 失败 0 项 |
| `./tests/contract/check_all.sh` | 191 + 47 | ✅ 通过 191 项 / 通过 47 项 / 全部校验通过 |
| `python3 tests/contract/verify_r2.py` | 123 | ✅ 结构 30 + 落地 65 + 归零 16 + 一致 10 + 自洽 2 |
| `python3 tests/contract/verify_counts.py` | 全部一致 | ✅ 一致 9 项 / 不一致 0 项 / 未覆盖 4 项 |
| `python3 tests/contract/verify_doc_claims.py` | 一致 29 条 / 0 不一致 | ✅ 一致 29 条 / 不一致 0 条 / 未覆盖 6 条 |

## 八、已知缺口（如实登记）

- **tag 触发路径没有在 CI 里真跑过**。CI 只验证 workflow 文件能解析，不验证 `gh release create` 真的成功 —— 只有真正推一个 tag 才会走到那段分支。验不了的项按 CLAUDE.md §六 归入 A-10 发布准入，本单不假装它已被验证。
- 下一次发版若仍走 `workflow_dispatch`，本修复不会被执行到；两条路径都通，但**只有 tag 路径被本单修好**。
