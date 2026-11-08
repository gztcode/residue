# -*- coding: utf-8 -*-
import re
new = open('Residue-PRD-v4.1.md', encoding='utf-8').read().split('\n')
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
print('【3】v4.1 新增基础定义')
checks3 = [
  ('观察期终点=日历事件', '**观察期结束扫描** = 第 14 个自然日结束后的**第一次成功扫描**'),
  ('未达标自动开下一轮', '若该轮未达标（存在任一来源 `K < H`），自动开启下一轮'),
  ('失联是派生量', '`J = T − K − 本轮重建命中数`'),
  ('inode 判据已删', '**该判据已删**'),
  ('pipx 行取值', '**`pipx` run 行（非判定域）的取值**'),
  ('期内不展示 KTJ', '**期内不展示 `K` / `T` / `J`**'),
  ('空域成因分界', 'CLI 缺失或探测失败一律归「错误」、空态不出现'),
  ('点亮后果告知', '本版本点亮后不会自动回退'),
  ('b >= 1', 'L0 检查次数 `b ≥ 1`'),
  ('H 不上界面', '**不把公式画到界面上**'),
]
for tag, s2 in checks3:
    c = C(s2); print('  [%s] %-20s %d' % ('OK ' if c>=1 else 'MISS', tag, c))
    if c<1: fail.append(tag)
c = C('inode 与 birthtime 均不匹配 → 归「目录拆分合并」')
print('  [%s] %-20s %d' % ('OK ' if c==0 else 'LEFT', '旧 inode 判据残留', c))
if c: fail.append('旧 inode 判据残留')
c = C('截至今日 样本 29')
print('  [%s] %-20s %d' % ('OK ' if c==0 else 'LEFT', '期内示例残留', c))
if c: fail.append('期内示例残留')
print()
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
