#!/usr/bin/env python3
"""校验「CI 注释与发布说明里声明的项数」与「实测值」一致。

## 为什么需要这个脚本

这些数字曾一次性漂移 6 处（243 单测 / 51 项 / 36 项 / 40 项 / R2 v1.7 / 124 项），
而**没有任何判据守着它们**：
- `.github/workflows/ci.yml` 是活配置，描述「本 workflow 现在验什么」；
- `.github/workflows/release.yml` 的发布说明每次发版都会贴到公开 Release 页。

两者都不是历史档案。按 `ARCHITECTURE.md:5` 的口径 ——
「代码里每一条硬约束都能在文档里找到出处，每一条文档里的判据都有对应的机器校验。
两边对不上就是缺陷，不是『文档过时了』」。

本脚本把这条纪律变成机器断言：数字对不上就红。

## 覆盖范围（如实标注）

能实测的：单测数 / verify_a9 / verify_codes / PRD 基线 / R2 基线。
测不了的：`--verify-wiring`（需编译产物）、`verify_a5`（需先打包 .app）——
这两项输出为「未覆盖」，不猜、不假装通过。

用法：`python3 tests/contract/verify_counts.py`（任意 cwd）
"""

import glob
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
APP = os.path.join(ROOT, 'ResidueApp')
WORKFLOWS = sorted(glob.glob(os.path.join(ROOT, '.github', 'workflows', '*.yml')))

FAIL, OK, SKIP = [], [], []


def run(cmd, cwd, timeout=120):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)


# ── 实测 ──────────────────────────────────────────────────────────
def actual_tests():
    n = 0
    for p in glob.glob(os.path.join(APP, 'Tests', '**', '*.swift'), recursive=True):
        with open(p, encoding='utf-8') as f:
            n += f.read().count('func test')
    return n


def actual_a9():
    p = run([os.path.join(APP, 'scripts', 'verify_a9.sh')], APP)
    m = re.search(r'通过 (\d+) 项 / 失败 (\d+) 项', p.stdout)
    return int(m.group(1)) if m else None


def actual_codes():
    p = run([sys.executable, os.path.join(APP, 'scripts', 'verify_codes.py')], APP)
    m = re.search(r'通过 (\d+) 项 / 失败 (\d+) 项', p.stdout)
    return int(m.group(1)) if m else None


def actual_prd():
    p = run([os.path.join(ROOT, 'tests', 'contract', 'check_all.sh')], ROOT)
    vals = [int(x) for x in re.findall(r'通过 (\d+) 项', p.stdout)]
    return sum(vals) if vals else None


def actual_r2():
    p = run([sys.executable, os.path.join(HERE, 'verify_r2.py')], ROOT)
    m = re.search(r'结构 (\d+) \+ 落地 (\d+) \+ 归零 (\d+) \+ 一致 (\d+) \+ 自洽 (\d+)', p.stdout)
    return sum(int(g) for g in m.groups()) if m else None


# ── 声明（从 workflow 注释与发布说明里提取）──────────────────────────
# 每条声明 = (要核对的量, 文件, 行号, 声明值)。只认**带描述文字**的模式，
# 不按行号锚定 —— 锚行号会在别人插入注释后失效，制造新的假红/假绿。
CLAIMS = [
    ('单测', r'(\d+)\s*个单测'),
    ('单测', r'(\d+)\s*单测全绿'),
    ('a9', r'(\d+) 项：语义位类型化'),
    ('codes', r'码表 (\d+) 项'),
    ('prd', r'(\d+) 项（191 \+ 47）'),
    ('prd', r'PRD (\d+) 项'),
    ('r2', r'(\d+) 项：R2 v(\d+\.\d+)'),
    ('r2', r'R2 (\d+) 项'),
    ('wiring', r'(\d+) 项：\*\*真的走一遍\*\*'),
    ('wiring', r'接线自检 (\d+) 项'),
    ('a5', r'(\d+) 项：bundle 结构'),
    ('a5', r'产物结构 (\d+) 项'),
]


def scan_claims():
    found = []
    for wf in WORKFLOWS:
        with open(wf, encoding='utf-8') as f:
            for lineno, line in enumerate(f, 1):
                for kind, pat in CLAIMS:
                    for m in re.finditer(pat, line):
                        found.append((kind, os.path.relpath(wf, ROOT), lineno, int(m.group(1))))
    return found


# ── 比对 ──────────────────────────────────────────────────────────
def main():
    actual = {
        '单测': actual_tests(),
        'a9': actual_a9(),
        'codes': actual_codes(),
        'prd': actual_prd(),
        'r2': actual_r2(),
    }

    # 中文键统一成内部名，便于查表
    for kind, path, lineno, claimed in scan_claims():
        if kind in ('wiring', 'a5'):
            SKIP.append(f'{path}:{lineno}  {kind} 声明 {claimed}（需编译/打包，本脚本不实测）')
            continue
        real = actual.get(kind)
        if real is None:
            FAIL.append(f'{path}:{lineno}  {kind} 声明 {claimed}，但实测没拿到数字（脚本可能挂了）')
        elif real != claimed:
            FAIL.append(f'{path}:{lineno}  {kind} 声明 {claimed}，实测 {real}')
        else:
            OK.append(f'{path}:{lineno}  {kind} = {real}')

    print('=' * 60)
    print('CI 声明项数 ↔ 实测值')
    print('=' * 60)
    for s in OK:
        print(f'  ✓ {s}')
    for s in FAIL:
        print(f'  ✗ {s}')
    for s in SKIP:
        print(f'  △ {s}')
    print('-' * 60)
    print(f'一致 {len(OK)} 项 / 不一致 {len(FAIL)} 项 / 未覆盖 {len(SKIP)} 项')
    if FAIL:
        print('\n❌ 声明与实测不符 —— 改注释，不要改实测值去迁就注释。')
        return 1
    print('\n✅ 全部一致')
    return 0


if __name__ == '__main__':
    sys.exit(main())
