#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Residue PRD · 「已实删」声明的全文命中核验

背景（第 15 轮质量评审的硬要求）：

> **本单不接受「声明」作为修法证据** —— 下轮凡标「已实删 / 已统一」，须附
> **全文检索命中数 = 0**（变更清单登记行与归零标注除外）。

本脚本**自动**做这件事，不依赖人读：
  1. 扫描变更清单里所有含「已实删 / 已归零 / 已作废 / 已统一 / 已搬回」等**声明动词**的行；
  2. 从这些行的括注里**提取被声明已删/已改的原文**（中文引号「」内的文本）；
  3. 在**生效正文**里全文检索这些文本 —— 命中数必须为 0。

「生效正文」的排除范围（与评审约定一致）：
  - 变更清单的登记行本身（即声明「已实删」的那一行）
  - 「归零标注」行（即专门记录「旧口径已归零」的历史留痕行）

用法：python3 verify_claims.py [PRD路径]
"""
import sys, re

# 默认：自动选目录下版本号最大的 Residue-PRD-v*.md
# （踩过的坑：写死 v5.1 会核旧稿却打印「全部通过」——见第 18 轮 S18-07）
def _latest_prd():
    import glob as _g
    import re as _re
    cands = sorted(_g.glob('Residue-PRD-v*.md'),
                   key=lambda p: [int(x) for x in _re.findall(r'[0-9]+', p)])
    return cands[-1] if cands else 'Residue-PRD-v5.3.md'


P = sys.argv[1] if len(sys.argv) > 1 else _latest_prd()
TXT = open(P, encoding='utf-8').read()
L = TXT.split('\n')

CLAIM_VERBS = ['已实删', '已归零', '已作废', '已统一', '已搬回', '已删除', '已换成']
# 「旧口径已实删」这类**归零标注行**是合法留痕，不参与被删文本的提取
DEAD_MARKERS = ['已归零', '已作废', '已实删', '已删除', '旧口径已', '本行旧', '已搬回']

# 变更清单登记行：位于「相对 vX.Y 的变更清单」小节内
# 变更清单小节的行号区间（一次性算好）
# ⚠ 区间必须在**下一个 `## ` 标题处**关闭，不能只等下一个「变更清单」标题——
#   否则最后一个变更清单小节会把**其后全部正文**误判为变更清单
#   （v5.4 实测：L736 的 v4.0 变更清单曾吞掉 L736→EOF 共 575 行，
#     使 AC / N7 / M4 等**全部规范正文**被当成「历史留痕」而绕过本脚本的校验）。
CHANGE_LIST_RANGES = []
_i = None
for _k, _ln in enumerate(L):
    if _i is not None and _ln.startswith('## '):
        CHANGE_LIST_RANGES.append((_i, _k - 1))
        _i = None
    if _ln.startswith('## 相对 v') and '变更清单' in _ln:
        _i = _k
if _i is not None:
    CHANGE_LIST_RANGES.append((_i, len(L) - 1))


def in_change_list(idx):
    """判断某行是否属于任一「变更清单」小节（表格登记行 / 历史留痕行）"""
    return any(a <= idx <= b for a, b in CHANGE_LIST_RANGES)


claims = []   # (声明行号, 被删文本, 声明动词)
for i, line in enumerate(L):
    if not any(v in line for v in CLAIM_VERBS):
        continue
    if not in_change_list(i):
        continue
    # 提取中文引号内、且**紧邻声明动词**的文本 —— 视为「被声明已删的原文」
    for m in re.finditer(r'[「『]([^」』]{4,120})[」』]', line):
        text = m.group(1)
        # 该引号文本后面 40 字内出现声明动词 → 视为被删文本
        tail = line[m.end():m.end() + 60]
        if any(v in tail for v in CLAIM_VERBS):
            claims.append((i + 1, text, [v for v in CLAIM_VERBS if v in tail][0]))

print('=' * 64)
print('PRD: %s' % P)
print('扫描到「已实删类」声明 %d 处，被声明的文本 %d 条\n' % (
    len(set(c[0] for c in claims)), len(claims)))

FAIL = []
OK = 0

# 判定「生效正文」：排除 ① 变更清单登记行 ② 归零标注行
def is_effective(idx, text):
    """判断该行是否为「生效正文」

    排除三类合法留痕：
      ① 变更清单的登记行
      ② 文件头的版本行 / 历史留痕行（元信息，不是条文）
      ③ **作废登记句**（行内声明「已实删/已归零」并**引述**了该旧文本）
         —— 评审约定：归零标注除外。
    """
    line = L[idx]
    if in_change_list(idx):
        return False
    # ② 文件头版本行 / 历史留痕行
    if line.startswith('> 版本：') or line.startswith('> 历史留痕：'):
        return False
    if text in line:
        # 该行引述了这个旧文本 —— 判断它是不是「作废登记句」
        # 判据：同一行内出现声明动词 + 旧文本被引号包裹 → 视为作废登记
        for m in re.finditer(r'[「『]([^」』]{4,120})[」』]', line):
            if m.group(1) == text:
                tail = line[m.end():m.end() + 60]
                if any(v in tail for v in CLAIM_VERBS):
                    return False   # 作废登记句 → 合法留痕
                break
    return True

seen = set()
for lineno, text, verb in claims:
    key = (lineno, text)
    if key in seen:
        continue
    seen.add(key)
    hits = []
    for idx, line in enumerate(L):
        if text in line and is_effective(idx, text):
            hits.append(idx + 1)
    if hits:
        FAIL.append((lineno, text, verb, hits))
    else:
        OK += 1
        print('  ✓ L%-5d %s 「%s…」' % (lineno, verb, text[:40]))

print()
if FAIL:
    print('失败 %d 条（被声明已删的文本仍在生效正文）：' % len(FAIL))
    for lineno, text, verb, hits in FAIL:
        print('  ✗ 声明于 L%d（%s）：「%s…」 → 仍在生效正文 L%s' % (
            lineno, verb, text[:44], hits))
    sys.exit(1)
print('全部通过：%d 条「已实删」声明的全文命中数均为 0' % OK)
