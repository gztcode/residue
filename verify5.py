# -*- coding: utf-8 -*-
"""v3.8 按一致性矩阵逐行复核（不再以字符串自查为主要手段，此处只作格内确认）"""
import re
new = open('Residue-PRD-v3.8.md', encoding='utf-8').read().split('\n')
fail = []


def body_only():
    out, skip = [], False
    for t in new:
        if t.startswith('## 相对 v'):
            skip = True
        if t.startswith('## ') and not t.startswith('## 相对 v'):
            skip = False
        if not skip:
            out.append(t)
    return out


B = body_only()
C = lambda s: sum(t.count(s) for t in B)

print('=' * 76)
print('矩阵六条判据 × 10 个量')
print()
rows = [
    ('K-1 / Q3 行内一致', [
        ('S2 定稿段已改按 N−1 键', 'U1 退回是版本切换**（N → N−1），L0 按 **(来源, N−1) 键**重取'),
        ('「保留」只留熔断回退', '**同版本内的熔断回退**保留 L0 误判计数'),
        ('威胁面承认退回缺口', '用户可通过 U1 退回回到一个 L0 记录更干净的旧版本'),
        ('禁止对外宣称无法绕过', '不得对外宣称「用户无法自助洗记录」'),
    ], [('旧口径残留', '（熔断回退 / U1 退回）L0 误判计数')]),
    ('K-2 / Q2 格内单义 + 列内不蕴含', [
        ('③ 三数 K/T/J', '「样本 `<K>` / 总量 `<T>`（其中失联 `<J>`）」'),
        ('K+J = T 为等号', '`K + J = T`'),
        ('④ 只放门槛', '④门槛 = `N` 且 **`N = min(30, T)` 可算出**'),
        ('两列不得同值', '两列不得同值'),
    ], [('K+J ≤ N 旧式', 'K + J ≤ N'), ('旧列名 双值残留', '样本·门槛 双值 / L2')]),
    ('K-3 / Q10 列内不互斥', [
        ('08A Given 加空域前置', '**判定域非空**（至少一个来源候选总量 ≥ 1；**空域时本组不适用**'),
    ], []),
    ('K-4 / Q2 恒真消除', [
        ('08B 加报告已生成', '**且 AC-09 报告已生成**'),
        ('08B 加 T ≥ 1', '观察期开始快照总量 T ≥ 1'),
        ('N ≥ 1 说明', '恒 ≥ 1**、不会退化为 0'),
    ], []),
    ('K-5 / Q7 算术可验', [
        ('区间改 7 日', '[T−13, T−7]'),
        ('写明共 7 个自然日', '共 7 个自然日'),
        ('口径写明判据', '删除日 ≤ T−7'),
    ], []),
    ('K-6 / Q9 单一判据', [
        ('阈值对象=可回收字节', '14 日前历史部分的字节合计（即可回收字节）'),
        ('回收单位=整条记录', '回收单位 = 整条记录'),
        ('可回收为 0 时的行为', '可回收字节为 0、容量条件不成立、不回收任何记录'),
        ('对外口径三方一致', '90 天，或 14 日外历史满 200 MB，先到者为准'),
    ], [('旧口径残留', '90 天或 200 MB，先到者为准')]),
    ('K-7 / §6 有要求必有断言', [
        ('②页标签断言', '第 ② 页候选清单每行带标签且取值 ∈ {可参与自动删除 / 仅报告}'),
        ('页级状态行断言', '页级状态行「本轮可点亮」取值须与 AC-08 组 B 的开关状态一致'),
        ('结论与数值交叉', '「达标」⟺ `K ≥ N` 且 `a = 0`'),
    ], []),
    ('K-8 / 义项无落点', [
        ('本期无实例登记', '本期无实例'),
    ], []),
    ('K-9 / 同量异时点', [
        ('③ 截至今日', '截至今日'),
        ('⑤ 冻结于', '冻结于'),
    ], []),
]
for name, must, mustnot in rows:
    print('【%s】' % name)
    for tag, s in must:
        c = C(s)
        print('   [%s] %-22s %d' % ('OK ' if c else 'MISS', tag, c))
        if not c:
            fail.append(name + ' 缺：' + tag)
    for tag, s in mustnot:
        c = C(s)
        print('   [%s] %-22s %d' % ('OK ' if c == 0 else 'LEFT', tag, c))
        if c:
            fail.append(name + ' 残留：' + tag)
    print()

print('【算术走查】')
cases = [
    ('T=100, J=3 → K=97, N=30', 97 >= 30, '达标（K+J=100=T，旧式 K+J≤N 会判假）'),
    ('T=20, J=0 → K=20, N=20', 20 >= 20, '达标'),
    ('T=30, J=3 → K=27, N=30', 27 >= 30, '未达标（正确：失联挤掉样本）'),
    ('T=1, J=0 → K=1, N=1', 1 >= 1, '达标，且 N ≥ 1 不退化'),
    ('S4: 第 7 日结算，删除日∈[T−13,T−7]', True, '区间为 7 个自然日（T−13..T−7 共 7 个），与滚动 7 日重合'),
    ('N7: 总 350MB，14 日内占 300MB', 350 - 300 < 200, '可回收 50MB < 200MB → 不回收，终态唯一'),
]
for name, ok, why in cases:
    print('   %-38s → %s  %s' % (name, '成立' if ok else '不成立', why))

print()
print('【AC 覆盖】')
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
print('   AC 数 %d；编号连续 %s' % (len(bn), [k for k in sorted(bn)] == ['AC-%02d' % i for i in range(1, 21)]))

print()
print('=' * 76)
print('结论：%s' % ('全部通过' if not fail else '有 %d 项需处理' % len(fail)))
for f in fail:
    print('  -', f)
