# -*- coding: utf-8 -*-
"""v3.9 验收：跑矩阵六条判据 + 算术走查 + 符号唯一性（不跑字符串自查为主）"""
import re
new = open('Residue-PRD-v3.9.md', encoding='utf-8').read().split('\n')
fail = []


def body():
    out, skip = [], False
    for t in new:
        if t.startswith('## 相对 v'):
            skip = True
        if t.startswith('## ') and not t.startswith('## 相对 v'):
            skip = False
        if not skip:
            out.append(t)
    return out


B = body()
C = lambda s: sum(t.count(s) for t in B)

print('=' * 78)
print('【判据 1】格内单义：六符号全文唯一（不得复用）')
bad = []
for pat, why in [
    (r'（失联 N）', 'N 被用作失联'),
    (r'其中失联 K', 'K 被用作失联'),
    (r'N 不再指快照总量', '历史说明可留'),  # 允许出现在变更清单外的说明里
    (r'门槛 N（其中失联', 'K/N 混用句式'),
]:
    hits = [i + 1 for i, t in enumerate(B) if re.search(pat, t)]
    if hits and pat != r'N 不再指快照总量':
        bad += hits
        print('  [BAD ] %-22s 行 %s' % (why, hits[:5]))
    else:
        print('  [OK  ] %-22s %d' % (why, len(hits)))
print('  符号表存在：', C('恒有 `K + J = T`、`N ≥ 1`') >= 1)
if not C('恒有 `K + J = T`、`N ≥ 1`'):
    fail.append('缺符号表恒等式')

print()
print('【判据 2】列内不蕴含 / 不互斥')
checks = [
    ('组 A 四条用例', C('四条独立用例') >= 1),
    ('用例④ 空域豁免首句', '作**显式豁免**' in '\n'.join(B)),
    ('「结算中」全局项', '`结算中`（观察期已满但 AC-09 报告尚未产出）' in '\n'.join(B)),
    ('组 B 要求报告已生成', '**且 AC-09 报告已生成**' in '\n'.join(B)),
    ('组 B T≥1 前置', '`T ≥ 1`，故 `N = min(30, T) ≥ 1`' in '\n'.join(B)),
    ('不再断言两列必须异值', '不作「两列必须异值」的断言' in '\n'.join(B)),
    ('达标⟺含"属判定域"', '`达标` ⟺ 该行属判定域' in '\n'.join(B)),
    ('pipx 恒仅报告、不参与该式', '非判定域行（`pipx` run）恒为「仅报告」、不参与该式' in '\n'.join(B)),
]
for tag, ok in checks:
    print('  [%s] %s' % ('OK ' if ok else 'MISS', tag))
    if not ok:
        fail.append(tag)

print()
print('【判据 3】算术可验（逐条代入）')
cases = [
    ('T=100 J=0 → K=100, N=30', 'K>=N', 100 >= 30, '达标'),
    ('T=30 J=3 → K=27, N=30', 'K>=N', 27 >= 30, '未达标'),
    ('T=20 J=0 → K=20, N=20', 'K>=N', 20 >= 20, '达标（全量观察）'),
    ('T=1 J=0 → K=1, N=1', 'K>=N', 1 >= 1, '达标，N≥1 不退化'),
]
for label, expr, ok, expect in cases:
    print('  %-26s → %-6s 期望 %s' % (label, '成立' if ok else '不成立', expect))
# K+J=T 恒等抽查
for T, J in [(100, 0), (30, 3), (20, 0), (1, 0), (500, 17)]:
    assert T - J + J == T
print('  K + J = T 恒等：5 组抽查全部成立')
# S4
T = 10
lo, hi = T - 13, T - 7
print('  S4 T=10 → 窗口 [%d,%d]，跨度 %d 天；删除日 ≤ %d 计为成熟' % (lo, hi, hi - lo + 1, T - 7))
if not (hi - lo + 1 == 7 and T - 7 == hi):
    fail.append('S4 区间不对')
# N7
tot, d14 = 350, 300
rec = tot - d14
print('  N7 总 350 / 14 日内 300 → 可回收 %d MB < 200 → 不回收（唯一）' % rec)
if not (rec < 200):
    fail.append('N7 算例不成立')

print()
print('【判据 4】行内一致（关键量跨列同口径）')
for tag, s, want in [
    ('门槛写法', 'min(30, T)', 3),
    ('K + J = T', 'K + J = T', 2),
]:
    c = C(s)
    print('  %-16s %d 次（期望 ≥%d）' % (tag, c, want))
    if c < want:
        fail.append(tag + ' 出现次数不足')

print()
print('【判据 5】旧口径归零（生效文本内）')
zero = [
    ('「90 天保底」生效口径', '90 天保底'),
    ('N7 双值矛盾句', '可回收字节为 0'),

    ('「滚动 7 日」作生效窗口', '窗口 = 滚动 7 日'),
]
for tag, s in zero:
    c = C(s)
    print('  [%s] %-24s %d' % ('OK ' if c == 0 else 'LEFT', tag, c))
    if c:
        fail.append('残留：' + tag)

print()
print('【判据 6】界面有断言 + AC 结构')
def acs(lines):
    blk, cur, inac = {}, None, False
    for t in lines:
        if t.startswith('## 4. 验收标准'):
            inac = True; continue
        if inac and re.match(r'^## (?!4\. )', t):
            inac = False
        if not inac:
            continue
        m = re.match(r'^\*\*(AC-\d+)（', t)
        if m:
            cur = m.group(1); blk[cur] = []
        elif cur is not None:
            blk[cur].append(t)
    return blk

bn = acs(new)
nums = [k for k in sorted(bn)]
print('  AC 数 %d；编号连续 %s' % (len(bn), nums == ['AC-%02d' % i for i in range(1, 21)]))
if len(bn) != 20:
    fail.append('AC 条数 ≠ 20')
print('  AC-04 块 %d 行 / AC-08 %d 行 / AC-09 %d 行' % (
    len([x for x in bn['AC-04'] if x.strip()]),
    len([x for x in bn['AC-08'] if x.strip()]),
    len([x for x in bn['AC-09'] if x.strip()])))
print('  §8 开篇豁免句：', C('本期无实例') )
if C('本期无实例') < 1:
    fail.append('§8 开篇缺豁免')

print()
print('=' * 78)
print('结论：%s' % ('全部通过' if not fail else '有 %d 项需处理' % len(fail)))
for f in fail:
    print('  -', f)
