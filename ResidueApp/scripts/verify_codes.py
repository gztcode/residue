#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Residue · 错误码表一致性校验

## 它存在的理由

R3 契约维度评审（梁承重）指出的结构性问题：
**`"E-xxx"` 字面量在 Sources 里出现 0 次，23 个码全部只活在注释里。**
后果是「码 ↔ 用例」逐条核对无法机器化，而且改了码不会被发现。

码表已代码化（`Sources/ResidueCore/DiagnosticCode.swift`），
本脚本负责钉住**代码与文档之间**的一致性——这是代码化之后仍然会漂的那一层。

## 校验项（六段）

A. **码集合双向一致**：代码的 24 个码 == R2 §6 的码集合（多一个少一个都失败）
B. **无重复定义**：同一码不得出现两次
C. **界面层不得硬编码码**：除 `DiagnosticCode.swift` 外，`"E-xxx"` 字面量应为 0
D. **归类值域封闭**：`category` 只能取 §8 的五类 + P4 的 undetermined
E. **三类受阻各有码**：AC-14 的 `E-108` / `E-202` / `E-501` 必须都归「无权限」
F. **测试覆盖**：每个码都在 `DiagnosticCodeTests` 里被断言过

用法：`python3 scripts/verify_codes.py [R2文件]`
不带参数时自动发现最新的 R2 技术方案。
"""

import os
import re
import sys
import glob

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)              # ResidueApp/
REPO = os.path.dirname(PROJECT)              # 仓库根
CODE_FILE = os.path.join(PROJECT, 'Sources/ResidueCore/DiagnosticCode.swift')
TEST_FILE = os.path.join(PROJECT, 'Tests/ResidueCoreTests/DiagnosticCodeTests.swift')
SRC_DIR = os.path.join(PROJECT, 'Sources')

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print('  \u2713 ' + msg)


def bad(msg):
    global FAIL
    FAIL += 1
    print('  \u2717 ' + msg)


def find_r2():
    """自动发现最新的 R2 技术方案（不写死版本号）。"""
    if len(sys.argv) > 1:
        return sys.argv[1]
    cands = sorted(glob.glob(os.path.join(REPO, 'docs', 'contract', 'Residue-R2-技术方案-v*.md')))
    if not cands:
        return None
    # 按版本号排序（v1.10 > v1.9）
    def ver(p):
        m = re.search(r'v(\d+)\.(\d+)', os.path.basename(p))
        return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    return sorted(cands, key=ver)[-1]


def main():
    r2 = find_r2()
    if not r2:
        print('!! 找不到 R2 技术方案，无法校验')
        return 2

    print('=' * 60)
    print('Residue · 错误码表一致性校验')
    print('  代码：%s' % os.path.relpath(CODE_FILE, REPO))
    print('  文档：%s' % os.path.basename(r2))
    print('=' * 60)

    if not os.path.exists(CODE_FILE):
        print('!! 码表文件不存在：%s' % CODE_FILE)
        return 2

    code_src = open(CODE_FILE, encoding='utf-8').read()
    doc_src = open(r2, encoding='utf-8').read()

    # ---------------- A. 码集合双向一致 ----------------
    print('\n--- A. 码集合双向一致（代码 vs R2 §6）---')
    # 代码侧：case xxx = "E-1xx"
    code_codes = re.findall(r'case\s+\w+\s*=\s*"(E-\d{3})"', code_src)
    code_set = set(code_codes)

    # 文档侧：§6 错误码表区间内的 `E-xxx`
    i = doc_src.find('## 6. 错误码表')
    j = doc_src.find('## 7.', i) if i >= 0 else -1
    if i < 0 or j < 0:
        bad('文档里找不到 §6 错误码表区间')
        doc_set = set()
    else:
        doc_set = set(re.findall(r'`(E-\d{3})`', doc_src[i:j]))

    only_code = sorted(code_set - doc_set)
    only_doc = sorted(doc_set - code_set)

    if not only_code and not only_doc:
        ok('码集合完全一致（%d 个）' % len(code_set))
    else:
        if only_code:
            bad('代码有、文档无：%s —— 文档未跟上代码（须出变更单补文档）' % only_code)
        if only_doc:
            bad('文档有、代码无：%s —— 码只活在文档里（等于没实现）' % only_doc)

    # ---------------- B. 无重复定义 ----------------
    print('\n--- B. 无重复定义 ---')
    dupes = sorted({c for c in code_codes if code_codes.count(c) > 1})
    if dupes:
        bad('重复定义的码：%s' % dupes)
    else:
        ok('无重复定义的码')

    # ---------------- C. 界面层不得硬编码码 ----------------
    print('\n--- C. 界面层不得硬编码码 ---')
    offenders = []
    for path in glob.glob(os.path.join(SRC_DIR, '**', '*.swift'), recursive=True):
        if os.path.abspath(path) == os.path.abspath(CODE_FILE):
            continue          # 码表本体是唯一允许写字面量的地方
        src = open(path, encoding='utf-8').read()
        for lineno, line in enumerate(src.split('\n'), 1):
            # 跳过注释行
            stripped = line.strip()
            if stripped.startswith('//') or stripped.startswith('///'):
                continue
            if re.search(r'"E-\d{3}"', line):
                offenders.append('%s:%d' % (os.path.relpath(path, REPO), lineno))
    if offenders:
        bad('码表之外出现码字面量（应引用 DiagnosticCode.x.rawValue）：%s' % offenders[:6])
    else:
        ok('码字面量只出现在 DiagnosticCode.swift 一处')

    # ---------------- D. 归类值域封闭 ----------------
    print('\n--- D. 归类值域封闭（§8 五类 + P4 undetermined）---')
    m = re.search(r'enum Category[^{]*\{(.*?)\n    \}', code_src, re.S)
    if not m:
        bad('找不到 Category 枚举')
    else:
        cases = re.findall(r'case\s+\w+\s*=\s*"([^"]+)"', m.group(1))
        allowed = {'错误', '无权限', '加载', '超时', '并发冲突', '无法判定'}
        extra = sorted(set(cases) - allowed)
        if extra:
            bad('Category 出现 §8 之外的取值：%s —— §8 封闭分类被打破' % extra)
        else:
            ok('Category 取值 %d 个，全在 §8 封闭域内' % len(cases))

        # 每个码的 category 必须能求值（switch 覆盖完整 → 编译期保证；
        # 这里只核「映射里出现的码数」是否等于码总数）
        mapped = re.findall(r'case \.(e\d+):\s*return', code_src)
        # 注意：summary / suggestedAction 也各有 switch，所以数量是 3 倍左右
        if len(set(mapped)) == len(code_set):
            ok('每个码都有 category 映射（%d / %d）' % (len(set(mapped)), len(code_set)))
        else:
            bad('category 映射不完整：%d 个码，只映射了 %d 个'
                % (len(code_set), len(set(mapped))))

    # ---------------- E. AC-14 三类受阻各有码 ----------------
    print('\n--- E. AC-14 三类受阻各有「无权限」码 ---')
    # 在 category 的 switch 里定位三条
    expected = {'e108': '来源不可读', 'e202': '废纸篓不可写', 'e501': '同 uid fd 枚举失败'}
    cat_block = ''
    cm = re.search(r'public var category: Category \{(.*?)\n    \}', code_src, re.S)
    if cm:
        cat_block = cm.group(1)
    for key, label in expected.items():
        pat = r'case \.%s:\s*return \.noPermission' % key
        if re.search(pat, cat_block):
            ok('%s（%s）归「无权限」' % (key.upper().replace('E', 'E-'), label))
        else:
            bad('%s（%s）未归「无权限」—— AC-14 该类的授权指引不会出现'
                % (key.upper().replace('E', 'E-'), label))

    # E-204 必须不归无权限
    if re.search(r'case \.e204:\s*return \.error', cat_block):
        ok('E-204（越界/符号链接）归「错误」，非「无权限」')
    else:
        bad('E-204 未归「错误」—— 它是安全拒绝，归无权限会让用户去授权一件本不该做的事')

    # ---------------- F. 测试覆盖 ----------------
    print('\n--- F. 每个码在测试里被断言过 ---')
    if not os.path.exists(TEST_FILE):
        bad('测试文件不存在：%s' % TEST_FILE)
    else:
        test_src = open(TEST_FILE, encoding='utf-8').read()
        # 测试里以 "E-xxx" 或 .eXXX 形式出现都算
        covered = set(re.findall(r'"(E-\d{3})"', test_src))
        uncovered = sorted(code_set - covered)
        if uncovered:
            bad('测试未断言这些码：%s' % uncovered)
        else:
            ok('全部 %d 个码在测试里被断言' % len(code_set))

        # 关键回归：EACCES 必须有用例（这是二分能成立的唯一证据）
        if 'testClassifyEACCESAsDenied' in test_src:
            ok('EACCES 有真实权限复现用例（二分不是改名字）')
        else:
            bad('缺 EACCES 真实复现用例 —— 二分可能只是改了名字')

    # ---------------- 汇总 ----------------
    print('\n' + '=' * 60)
    print('通过 %d 项 / 失败 %d 项' % (PASS, FAIL))
    print('=' * 60)
    return 0 if FAIL == 0 else 1


if __name__ == '__main__':
    sys.exit(main())
