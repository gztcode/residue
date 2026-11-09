# 任务：修复 issue #{{ISSUE}}

前提：`AUTO_RESULT.json` 里已有 `reproduced: true`，失败测试已经在仓库里。
如果这个前提不成立，**立刻停止**，把 `blocked` 写进结果文件。

---

## 1. 先确认测试仍然红

```bash
cd ResidueApp
swift test --filter "<test_file 里记的 TestClass>/<test_name>"
```

必须**失败**。如果它现在是绿的，说明基线变了或在 triage 阶段就没写对——
**停止**，写 `blocked: "triage 的失败测试在 main 上不红"`，不要继续改。

## 2. 改生产代码

- 只改让测试变绿所必需的最小范围。**不做顺手重构。**
- 必须遵守 `CLAUDE.md` §四 的五条不变量：
  1. 界面禁止算术（类型级）
  2. 同一判定只有一个实现处
  3. 不把未知判为安全（`nil ≠ 0`）
  4. 删之前先证明自己判得准
  5. 删除只做 rename 到废纸篓
- 改之前先读 `CLAUDE.md` §七 的踩坑清单，不要重新踩。
- 契约文档（`docs/contract/**`）**不许改**。如果修改必须改契约，**停止**并写
  `blocked: "需要变更单（CR）"`，说清要改哪一份契约的哪一条。

## 3. 跑全部校验

按顺序，任何一项红都要修到绿：

```bash
cd ResidueApp
swift build
swift build -c release
swift test
./scripts/verify_a9.sh
python3 scripts/verify_codes.py
swift run --disable-sandbox ResidueApp --verify-wiring /tmp/residue-auto-wiring

cd ..
./tests/contract/check_all.sh
python3 tests/contract/verify_r2.py
python3 tests/contract/verify_counts.py
```

`./scripts/verify_a5.sh` 需要先 `make_app.sh` 打包，**跳过它**并在结果里注明。

## 4. 更新结果

把 `AUTO_RESULT.json` 补成：

```json
{
  "issue": {{ISSUE}},
  "reproduced": true,
  "fixed": true,
  "blocked": "",
  "files_changed": ["ResidueApp/Sources/ResidueCore/Xxx.swift"],
  "tests_changed": ["ResidueApp/Tests/ResidueCoreTests/XxxTests.swift"],
  "verification": {
    "swift_test": "283 tests, 0 failures",
    "verify_a9": "72/0",
    "verify_codes": "11",
    "verify_wiring": "45/0",
    "check_all": "191+47",
    "verify_r2": "123",
    "verify_counts": "9/0"
  },
  "summary": "一句话说清改了什么、为什么这样改才符合契约"
}
```

数值必须是**真实运行结果**，不能照抄上面的示例。

如果任何一步修不动：`fixed: false`，`blocked` 写清卡在哪，
`verification` 里保留已跑过的真实结果。**卡住不算失败，谎报才算。**

---

## 硬约束

- 不要 `git commit` / `git push`。提交由外层脚本在验收通过后做。
- 不要为了让测试变绿而改测试的期望值。测试是判据，不是障碍。
- 不要在 `Sources/` 里新增网络调用、文件删除或 `rm`/`unlink`。
- 修不动就停。一个诚实的 `blocked` 比一个掩盖问题的绿 PR 有价值得多。
