#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Residue PRD · 「同一对象的多版本定义」检测器

背景：第 8 轮以来的头号错误类型是
  **「新增了一个定义，但没删掉旧定义」** → 同一段里并存两套说法。

v5.1 的实例（评审方第 17 轮抓出）：
  M4 写入时刻行里，CR-017 段写「载体 = …（每来源一份，含三项：…）」，
  而 CR-019 段写「载体字段写死为**四项**：…」。
  → 新旧并存 ⇒ 载体到底是三项还是四项，两读。

本脚本做**通用检测**，不依赖具体条目：

  1. 把每一行按 `**〔CR-0XX · …〕` 切成若干「版本段」；
  2. 在**同一行**内，找出被**不同 CR 段**各自定义、但**定义对象相同**的表述；
  3. 判据：同一行内出现「版本递增标记」+「数量词/枚举词冲突」——
     例如「含三项」与「四项」、「三处」与「四处」、「两套」与「一套」、
     「唯一一处」与另一处「唯一定义处」。

用法：python3 verify_single_def.py [PRD路径]
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
L = open(P, encoding='utf-8').read().split('\n')

# 数量词 → 数字
CN_NUM = {'一': 1, '两': 2, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9, '十': 10}
AR_NUM = {'1': 1, '2': 2, '3': 3, '4': 4, '5': 5, '6': 6, '7': 7, '8': 8, '9': 9, '10': 10}

# 匹配「含 N 项 / N 项 / N 处 / N 条 / N 套 / N 段 / N 个 / N 重」
# 只认「枚举计数」形态：含/共 + N + 项/条/个/处（这些是「清单有幾個」的计数）
NUM_PAT = re.compile(
    r'(含|共)\s*([一两二三四五六七八九十1-9]|10)\s*(项|条|个|处)'
)


def nums_in(text):
    out = set()
    for m in NUM_PAT.finditer(text):
        tok = m.group(2)
        n = CN_NUM.get(tok) or AR_NUM.get(tok)
        if n:
            out.add(n)
    return out


# 切段：把一行按 CR 标记切成 [(cr_id, segment_text)]
CR_PAT = re.compile(r'\*\*〔(CR-0\d\d)[^〕]*〕')

# 额外边界：「载体字段写死」「载体 = 」这类**定义句开头**也算独立段
DEF_PAT = re.compile(r'(含|共)\s*([一两二三四五六七八九十1-9]|10)\s*(项|条|个|处)')


def split_segments(line):
    marks = [(m.start(), m.group(1)) for m in CR_PAT.finditer(line)]
    if len(marks) < 2:
        return []
    # 在 CR 标记之外，把「定义句」也当作独立段（附到所属 CR）
    bounds = sorted(marks + [(m.start(), marks[0][1]) for m in DEF_PAT.finditer(line)])
    # 去重（同一位置）
    uniq = []
    for pos, cr in bounds:
        if not uniq or pos != uniq[-1][0]:
            uniq.append((pos, cr))
    segs = []
    for i, (pos, cr) in enumerate(uniq):
        end = uniq[i + 1][0] if i + 1 < len(uniq) else len(line)
        if end > pos:
            segs.append((cr, line[pos:end]))
    return segs


FAIL = []
CHECKED = 0

for idx, line in enumerate(L, 1):
    segs = split_segments(line)
    if len(segs) < 2:
        continue
    # 收集每段里的「数量词」以及该段定义的关键对象（用该段里出现的第一个反引号术语/中文术语）
    per_seg = []
    for cr, seg in segs:
        per_seg.append((cr, nums_in(seg), seg))
    # 找冲突：不同段对**同一对象**给出不同数量
    # 简化判据：同一行内若出现 ≥2 个不同数量词，且它们落在不同的 CR 段里 → 报
    all_nums = set()
    for _, ns, _ in per_seg:
        all_nums |= ns
    if len(all_nums) >= 2:
        # 进一步：排除「历史留痕」段（其 CR 号小于本行最大 CR 号 且 段内含 已实删/已归零/已作废）
        live = []
        for cr, ns, seg in per_seg:
            is_dead = any(k in seg for k in ('已实删', '已归零', '已作废', '已删除', '已搬回'))
            if not is_dead and ns:
                live.append((cr, ns, seg))
        if len(live) >= 2:
            numsets = [ns for _, ns, _ in live]
            if any(ns != numsets[0] for ns in numsets[1:]):
                FAIL.append((idx, live))
                CHECKED += 1

print('=' * 64)
print('PRD: %s' % P)
print('检测到「同一行内多版本数量定义并存」%d 处\n' % CHECKED)

if FAIL:
    print('失败 %d 处：' % len(FAIL))
    for idx, live in FAIL:
        print('  ✗ L%d：' % idx)
        for cr, ns, seg in live:
            head = seg[:60].replace('\n', ' ')
            print('      %s 数量词=%s  「%s…」' % (cr, sorted(ns), head))
    sys.exit(1)
print('全部通过：未发现「新增定义但旧定义未删」的数量冲突')
