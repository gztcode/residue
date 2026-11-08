# -*- coding: utf-8 -*-
import re
new = open('Residue-PRD-v4.0.md', encoding='utf-8').read().split('\n')
fail = []
def body():
    out, skip = [], False
    for t in new:
        if t.startswith('## 相对 v'): skip = True
        if t.startswith('## ') and not t.startswith('## 相对 v'): skip = False
        if not skip: out.append(t)
    return out
B = body(); C = lambda s: sum(t.count(s) for t in B)
print('='*76)
print('【1】符号唯一（生效文本内）')
for tag, s, want in [('H = min(30, T)', 'H = min(30, T)', 1),
                     ('K ≥ H', 'K ≥ H', 1),
                     ('K + J = T', 'K + J = T', 1)]:
    c = C(s); print('  [%s] %-18s %d' % ('OK ' if c >= want else 'MISS', tag, c))
    if c < want: fail.append(tag)
for tag, s in [('生效文本出现 K ≥ N', 'K ≥ N'), ('生效文本出现 H 与 N 混用', 'N = min')]:
    c = C(s); print('  [%s] %-18s %d' % ('OK ' if c == 0 else 'LEFT', tag, c))
    if c: fail.append(tag+' 残留')
print()
print('【2】收窄标记')
for tag, s in [('AC-16 本期不交付', 'CR-009 收窄：整条本期不交付'),
               ('S4 行本期不交付', '本期不交付 · CR-009'),
               ('S4 注本期不交付', '本注整段本期不交付'),
               ('收窄声明节', '## 首版范围收窄声明'),
               ('永久边界改挂应用版本', '应用更新后 L0 计数与观察期一并重置')]:
    c = C(s); print('  [%s] %-24s %d' % ('OK ' if c >= 1 else 'MISS', tag, c))
    if c < 1: fail.append(tag)
print()
print('【3】AC-08 四维版')
for tag, s in [('三条用例', '三条独立用例'),
               ('全局项只含观察期', '`观察期未满`。**其定义 = 已观察天数 < 14 天，或该次扫描尚未产出 AC-09 报告**'),
               ('无结算中未达项', '不另设状态'),
               ('空域成因二选一', '按空域实际成因呈现 §8「空」类对应义项'),
               ('文案三基数', '样本 27 / 总量 30（门槛 30，其中失联 3）')]:
    c = C(s); print('  [%s] %-22s %d' % ('OK ' if c >= 1 else 'MISS', tag, c))
    if c < 1: fail.append(tag)
c = C('`结算中` 处理'); print('  [%s] %-22s %d' % ('OK ' if c == 0 else 'LEFT', '「结算中」残留', c))
if c: fail.append('结算中残留')
print()
print('【4】算术走查')
for label, ok, why in [
    ('T=100,J=0 → K=100,H=30 达标', 100>=30, 'K≥H'),
    ('T=30,J=3 → K=27,H=30 未达标', 27>=30, 'K<H'),
    ('T=20,J=0 → K=20,H=20 达标', 20>=20, '全量观察'),
    ('T=1,J=0 → K=1,H=1 达标', 1>=1, 'H≥1'),
]:
    print('  %-30s → %s  (%s)' % (label, '成立' if ok else '不成立', why))
print('  K+J=T 抽查：', all(T-J+J==T for T,J in [(100,0),(30,3),(1,0),(500,17)]))
print()
print('【5】旧口径归零（生效文本）')
for tag, s in [('90 天保底', '90 天保底'), ('两列取值不得同值', '两列取值不得同值'),
               ('可回收字节为 0', '可回收字节为 0'), ('结算中作为未达项', '结算中（观察期已满但')]:
    c = C(s); print('  [%s] %-22s %d' % ('OK ' if c == 0 else 'LEFT', tag, c))
    if c: fail.append('残留：'+tag)
print()
print('【6】AC 结构')
def acs(lines):
    blk, cur, inac = {}, None, False
    for t in lines:
        if t.startswith('## 4. 验收标准'): inac = True; continue
        if inac and re.match(r'^## (?!4\. )', t): inac = False
        if not inac: continue
        m = re.match(r'^\*\*(AC-\d+)（', t)
        if m: cur = m.group(1); blk[cur] = []
        elif cur is not None: blk[cur].append(t)
    return blk
bn = acs(new); nums = sorted(bn)
print('  AC 数 %d；编号连续 %s' % (len(bn), nums == ['AC-%02d'%i for i in range(1,21)]))
if len(bn)!=20: fail.append('AC 条数≠20')
print()
print('='*76)
print('结论：%s' % ('全部通过' if not fail else '有 %d 项需处理' % len(fail)))
for f in fail: print('  -', f)
