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

能实测的：单测数 / verify_a9 / verify_codes / PRD 基线 / R2 基线 / verify_a5。
测不了的：`--verify-wiring`（需编译产物，且本脚本不跑 11 秒的重 IO）——
该项输出为「未覆盖」，不猜、不假装通过。

`verify_a5` 需要先有 `build/Residue.app`（CI 里 `make_app.sh` 在它之前跑）：
- 有产物 → 实测并核对；
- 没产物 → 「未覆盖」（不是失败，也不是假装通过）。

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


def run(cmd, cwd, timeout=120, env=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                          timeout=timeout, env=env)


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


# check_all.sh 会调 verify_doc_claims.py，而后者测 PRD 基线时又要回调 check_all.sh。
# 不带这个护栏就会无限递归，故调用时**必须**给子进程带上。
_PRD = {}


def _prd_run():
    if 'result' not in _PRD:
        env = dict(os.environ, RESIDUE_SKIP_DOC_CLAIMS='1')
        p = run([os.path.join(ROOT, 'tests', 'contract', 'check_all.sh')], ROOT,
                timeout=600, env=env)
        parts, section = {}, None
        for line in p.stdout.splitlines():
            m = re.match(r'^---\s+(\S+)\s+---$', line.strip())
            if m:
                section = m.group(1)
                continue
            m = re.search(r'通过 (\d+) 项', line)
            if m and section:
                parts[section] = parts.get(section, 0) + int(m.group(1))
        _PRD['result'] = (p.returncode, parts)
    return _PRD['result']


def actual_prd_parts():
    """PRD 基线各段的实测项数 → {段名: 项数}（段名 = check_all.sh 里的脚本名）。"""
    return _prd_run()[1]


def actual_prd():
    """PRD 基线总项数（各段之和）。基线挂了返回 None —— 实测没拿到数字，不猜。"""
    rc, parts = _prd_run()
    if rc != 0 or not parts:
        return None
    return sum(parts.values())


def actual_r2():
    p = run([sys.executable, os.path.join(HERE, 'verify_r2.py')], ROOT)
    m = re.search(r'结构 (\d+) \+ 落地 (\d+) \+ 归零 (\d+) \+ 一致 (\d+) \+ 自洽 (\d+)', p.stdout)
    return sum(int(g) for g in m.groups()) if m else None


def actual_a5():
    """产物结构校验实测 → (通过项数, 未覆盖项数)。

    没有 `build/Residue.app` 时返回 None（**未覆盖**，不猜）。
    脚本跑挂了抛异常（**实测失败**，判红 —— 不能把失败当成「没打包」）。
    """
    if not os.path.isdir(os.path.join(APP, 'build', 'Residue.app')):
        return None
    p = run([os.path.join(APP, 'scripts', 'verify_a5.sh')], APP, timeout=900)
    m = re.search(r'通过 (\d+) 项 / 失败 (\d+) 项 / 未覆盖 (\d+) 项', p.stdout)
    if not m:
        raise RuntimeError('verify_a5.sh 没输出「通过 N 项 / 失败 N 项 / 未覆盖 N 项」')
    return int(m.group(1)), int(m.group(3))


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

    a5, a5_error = None, None
    try:
        a5 = actual_a5()
    except Exception as e:
        a5_error = str(e)

    # 中文键统一成内部名，便于查表
    for kind, path, lineno, claimed in scan_claims():
        if kind == 'wiring':
            SKIP.append(f'{path}:{lineno}  {kind} 声明 {claimed}（需编译产物，本脚本不实测）')
            continue
        if kind == 'a5':
            if a5_error:
                FAIL.append(f'{path}:{lineno}  a5 实测失败：{a5_error}')
                continue
            if a5 is None:
                SKIP.append(f'{path}:{lineno}  a5 声明 {claimed}（没有 build/Residue.app，未打包不实测）')
                continue
            real = a5[0]
        else:
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
