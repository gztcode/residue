#!/usr/bin/env python3
"""核对「文档里声明的数字」与「实测值」。

## 为什么需要这个脚本

`tests/contract/` 此前只校验三份契约基线（PRD v5.6 / R2 v1.10 / CR-022）。
`docs/` 下 143 份文档里的**引用数、项数、结论**没有任何机器核对 ——
README 说「555 个单测」、ARCHITECTURE 说「产物结构（42 项）」、台账说「⚠️ 3 项未覆盖」，
这些数字漂了没人知道。

本脚本把「值得守的声明」登记成一张清单（`fixtures/doc_claims.json`），
每条声明都指向一个**可复算的实测来源**；数字对不上就红，并报出
「哪份文档的哪一行、声明多少、实测多少」。

## 收录边界：只守「值得守的声明」

- 只登记**描述当前状态**的数字（单测数、各校验脚本的项数、文档份数、错误码数）。
- **不登记**历史记录里的数字（台账里「A-5 校验 20 项 / 共 171 项」是当时的快照，
  登记它等于要求历史永远不变 —— 那是把历史记录当现状，是噪音）。
- 不登记正文里随口出现的数字（页码、条目序号、版本号）。

## 递归护栏

`check_all.sh` 会调本脚本；本脚本测 PRD 基线时又会调回 `check_all.sh`。
环境变量 `RESIDUE_SKIP_DOC_CLAIMS=1` 让被内层调用的本脚本**立即退出**，
避免无限递归。`verify_counts.py` 调 `check_all.sh` 时也带上它。

## 输出措辞

用「一致 N 条 / 不一致 N 条 / 未覆盖 N 条」——
**不能写「通过 N 项」**：`verify_counts.actual_prd()` 会对 `check_all.sh` 的输出
求和 `通过 (\\d+) 项`，本脚本在同一条输出里（check_all.sh 会调用它）会污染那个和。

用法：`python3 tests/contract/verify_doc_claims.py`（任意 cwd；忽略命令行参数）
"""

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(ROOT, 'ResidueApp')
FIXTURE = os.path.join(HERE, 'fixtures', 'doc_claims.json')

# 递归护栏：被 check_all.sh 内层调用时立即退出。
# 必须放在 import verify_counts 之前 —— 不跑任何东西。
if os.environ.get('RESIDUE_SKIP_DOC_CLAIMS') == '1':
    print('⊘ 跳过文档声明核对（递归护栏：调用方已在跑 PRD 基线校验）')
    sys.exit(0)

sys.path.insert(0, HERE)
import verify_counts as vc  # 复用同一份实测实现（不变量②：同一判定只有一个实现处）


# ── 实测来源 ────────────────────────────────────────────────────
# 每个指标 = 一个可复算的来源。返回 None 表示**环境不具备**（未覆盖，不猜）。
SOURCES = {
    'unit_tests': 'ResidueApp/Tests/**/*.swift 里 `func test` 的计数',
    'a9_items': 'ResidueApp/scripts/verify_a9.sh 的项数',
    'codes_items': 'ResidueApp/scripts/verify_codes.py 的项数',
    'r2_items': 'tests/contract/verify_r2.py 五段之和',
    'prd_items': 'tests/contract/check_all.sh 各段之和',
    'prd_structure_items': 'check_all.sh 里 verify18.py 段（PRD 结构落点）',
    'prd_cr022_items': 'check_all.sh 里 verify_cr022.py 段（CR-022 落地）',
    'wiring_items': '真跑一遍 .build/debug/ResidueApp --verify-wiring 的项数',
    'a5_items': 'ResidueApp/scripts/verify_a5.sh 的项数',
    'a5_uncovered': 'ResidueApp/scripts/verify_a5.sh 如实标未覆盖的项数',
    'docs_md': 'docs/ 下 .md 文件数',
    'diagnostic_codes': 'ResidueApp/scripts/verify_codes.py 汇总行的错误码个数',
}


def _prd_part(script):
    parts = vc.actual_prd_parts()
    if script not in parts:
        raise RuntimeError(f'check_all.sh 的 {script} 段没打印项数 —— 口径变了')
    return parts[script]


def _wiring_items():
    binary = os.path.join(APP, '.build', 'debug', 'ResidueApp')
    if not os.path.exists(binary):
        return None
    tmp = tempfile.mkdtemp(prefix='residue-doc-claims-')
    try:
        p = subprocess.run([binary, '--verify-wiring', tmp], cwd=APP,
                           capture_output=True, text=True, timeout=900)
        m = re.search(r'通过 (\d+) 项', p.stdout)
        if not m:
            raise RuntimeError('--verify-wiring 没打印项数')
        return int(m.group(1))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


_A5 = {}


def _a5():
    """verify_a5.sh 只跑一次 —— 挂 dmg 要十几秒，两个指标共用一份结果。"""
    if 'result' not in _A5:
        _A5['result'] = vc.actual_a5()
    return _A5['result']


def _diagnostic_codes():
    p = subprocess.run([sys.executable, os.path.join(APP, 'scripts', 'verify_codes.py')],
                       cwd=APP, capture_output=True, text=True, timeout=300)
    # 锚 A 段「码集合完全一致（24 个）」——这是代码 vs R2 §6 双向比对后的**权威计数**，
    # 不是从源码里另数一遍（不变量②）。
    m = re.search(r'码集合完全一致（(\d+) 个）', p.stdout)
    if not m:
        raise RuntimeError('verify_codes.py A 段没打印「码集合完全一致（N 个）」')
    return int(m.group(1))


METRICS = {
    'unit_tests': vc.actual_tests,
    'a9_items': vc.actual_a9,
    'codes_items': vc.actual_codes,
    'r2_items': vc.actual_r2,
    'prd_items': vc.actual_prd,
    'prd_structure_items': lambda: _prd_part('verify18.py'),
    'prd_cr022_items': lambda: _prd_part('verify_cr022.py'),
    'wiring_items': _wiring_items,
    'a5_items': lambda: (_a5() or (None, None))[0],
    'a5_uncovered': lambda: (_a5() or (None, None))[1],
    'docs_md': lambda: len(glob.glob(os.path.join(ROOT, 'docs', '**', '*.md'), recursive=True)),
    'diagnostic_codes': _diagnostic_codes,
}

_MEASURED = {}


def measure(metric):
    if metric not in _MEASURED:
        fn = METRICS.get(metric)
        if fn is None:
            raise RuntimeError(f'清单里出现未注册的指标「{metric}」')
        _MEASURED[metric] = fn()
    return _MEASURED[metric]


# ── 核对 ──────────────────────────────────────────────────────────
def check(claim):
    """核对一条声明 → (状态, 消息)。状态 ∈ ok / fail / skip。"""
    path = os.path.join(ROOT, claim['path'])
    if not os.path.isfile(path):
        return 'fail', f"{claim['path']}  文档不存在"
    with open(path, encoding='utf-8') as f:
        text = f.read()
    lines = text.splitlines()

    pattern = claim['pattern']
    group = claim.get('group', 1)
    tolerance = claim.get('tolerance', 0)

    hits = []
    for m in re.finditer(pattern, text):
        if m.re.groups < group or m.group(group) is None:
            continue
        hits.append((text.count('\n', 0, m.start()) + 1, int(m.group(group))))
    if not hits:
        return 'fail', (f"{claim['path']}  声明缺失：pattern「{pattern}」零命中 —— "
                        f"清单与文档脱节了")

    metric = claim['metric']
    try:
        measured = measure(metric)
    except Exception as e:
        return 'fail', f"{claim['path']}  实测失败（{metric}）：{e}"
    if measured is None:
        return 'skip', (f"{claim['path']}  {metric} 未实测"
                        f"（{SOURCES.get(metric, metric)} —— 环境不具备）")

    declared = claim.get('declared')
    for lineno, value in hits:
        src = lines[lineno - 1].strip() if lineno - 1 < len(lines) else ''
        if abs(value - measured) > tolerance:
            return 'fail', (f"{claim['path']}:{lineno}  声明 {value}，实测 {measured}"
                            f"（{metric}：{SOURCES.get(metric, metric)}）\n      原文：{src}")
        if declared is not None and abs(value - declared) > tolerance:
            return 'fail', (f"{claim['path']}:{lineno}  声明 {value} 与实测 {measured} 一致，"
                            f"但登记值是 {declared} —— 请把 fixtures/doc_claims.json 里"
                            f"这条的 declared 改成 {value}")
    return 'ok', f"{claim['path']}:{hits[0][0]}  {metric} = {measured}"


def main():
    if not os.path.isfile(FIXTURE):
        print(f'❌ 缺少声明清单：{os.path.relpath(FIXTURE, ROOT)}')
        return 1
    with open(FIXTURE, encoding='utf-8') as f:
        data = json.load(f)
    claims = data.get('claims', [])
    if not claims:
        print('❌ 声明清单是空的 —— 清单不得静默失效')
        return 1

    buckets = {'ok': [], 'fail': [], 'skip': []}
    for claim in claims:
        status, msg = check(claim)
        buckets[status].append(msg)

    print('=' * 60)
    print('文档声明 ↔ 实测值')
    print('=' * 60)
    for s in buckets['ok']:
        print(f'  ✓ {s}')
    for s in buckets['fail']:
        print(f'  ✗ {s}')
    for s in buckets['skip']:
        print(f'  △ {s}')
    print('-' * 60)
    print(f"一致 {len(buckets['ok'])} 条 / 不一致 {len(buckets['fail'])} 条 / "
          f"未覆盖 {len(buckets['skip'])} 条")
    if buckets['fail']:
        print('\n❌ 文档声明与实测不符 —— 改文档（连带清单里的 declared），'
              '不要改实测去迁就文档。')
        return 1
    print('\n✅ 全部一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
