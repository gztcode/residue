# -*- coding: utf-8 -*-
"""v3.6 -> v3.7 自查：11 个阻塞根因逐条验 + AC 变更范围"""
import re
old = open('Residue-PRD-v3.6.md', encoding='utf-8').read().split('\n')
new = open('Residue-PRD-v3.7.md', encoding='utf-8').read().split('\n')
fail = []


def cnt(lines, s):
    return sum(t.count(s) for t in lines)


print('=' * 74)
print('【1】旧措辞归零（v3.7 正文不应再有）')
zero = [
    ('H-3', '单独走满一个完整观察期'),
    ('H-6', 'L2 误判数 / L0 检查次数 / 结论'),
    ('H-5', '同版本内的熔断与 U1 退回保留 L0 计数'),
    ('H-5', 'L2 采用计数制：样本 ≥ 30 条'),
    ('H-2', '产品内不提供入口、无界面呈现'),
    ('H-2', '上述四类交付物**均无界面呈现**'),
    ('H-1', '总量与样本数取观察期开始快照）'),
    ('H-7', '逐来源复核仍满足本组'),
]
def cnt_body(s):
    # 跳过 v3.x 变更清单与注（描述性提及允许存在）
    body, skip = [], False
    for t in new:
        if t.startswith('## 相对 v'):
            skip = True
        if t.startswith('## ') and not t.startswith('## 相对 v'):
            skip = False
        if not skip:
            body.append(t)
    return sum(t.count(s) for t in body)

for tag, s in zero:
    c = cnt_body(s)
    flag = 'OK  ' if c == 0 else 'LEFT'
    if c:
        fail.append('%s 残留：%s' % (tag, s))
    print('  [%s] %-4s %-42s %d' % (flag, tag, s[:42], c))
# 历史清单里允许保留的（不计失败）
print('  （注：v3.6 及更早变更清单为历史留痕，允许出现旧措辞）')

print()
print('【2】新措辞必须存在')
have = [
    ('H-1 门槛分母固定', '门槛分母 = 观察期开始时的候选快照总量（固定，不因失联缩小）'),
    ('H-1 冻结时刻唯一', '冻结时刻唯一 = 观察期结束'),
    ('H-1 报告未产出', '该轮按「观察期未满」处理、组 B 不成立'),
    ('H-2 段首枚举', '以下四项中第 1–3 项为'),
    ('H-2 跳转入口限定', '产品内不提供指向 Issues 的对外跳转入口'),
    ('H-2 第⑦页控件', '承载于第 ⑦ 页既有「导出日志」控件'),
    ('H-3 全局窗口', '直到下一次全局观察期开始'),
    ('H-3 边界登记', '该来源本期不参与自动删除'),
    ('H-4 成熟度', '分母只计**删除已满 7 日**的条目'),
    ('H-4 累计出口', '分子与分母一并清零、回到滚动 7 日窗口重新起算'),
    ('H-4 随归零清', 'S4 的分子与分母随熔断归零一并清零'),
    ('H-5 N−1 键', 'U1 退回是版本切换、L0 按 (来源, N−1) 键重取'),
    ('H-5 L2 披露项', 'L2 改列第 ⑤ 页披露项并标「该来源不适用」'),
    ('H-6 复合列', 'L0 误判·检查（复合列，形如「误判 0 · 检查 128」）'),
    ('H-6 两项语义', '左值 = 误判次数（门槛项，须为 0）、右值 = 检查次数'),
    ('H-7 安全侧改挂', '本组不再重复断言，避免「仍满足本组」与「失格不出队」并存'),
    ('H-8 构造前置', '构造前置：判定域内仅一个来源'),
    ('H-9 显式豁免', '本用例对本条首句'),
    ('H-10 逐项值域', '①是否参与自动删除 ∈ {参与 / 仅报告}'),
    ('H-10 行集合条件式', '行集合为条件式'),
    ('H-11 14日豁免', '14 日内的执行记录不计入 200 MB 容量回收范围'),
    ('H-11 计量对象', '计量对象 = 单一本机目录内全部 `.jsonl` 的字节合计'),
    ('H-11 交叉前提', '本承诺的前提 = N7 的「14 日内执行记录不计入 200 MB 容量回收」'),
]
bad = 0
for tag, s in have:
    c = cnt(new, s)
    if c == 0:
        bad += 1
        fail.append('缺新措辞：' + tag)
    print('  [%s] %-20s %d  %s' % ('OK ' if c else 'MISS', tag, c, s[:46]))
print('  → 缺失 %d 项' % bad)

print()
print('【3】数量词与列举（第⑤页仍为七项）')
for i, t in enumerate(new, 1):
    m = re.search(r'七项只读\*\*：\*\*([^*]{0,200})', t)
    if m:
        raw = re.sub(r'（[^）]*）', '', m.group(1))
        items = [x.strip() for x in raw.split('/') if x.strip()]
        print('  行 %d：七项列举 = %d 项 → %s' % (i, len(items), items))
        if len(items) != 7:
            fail.append('第⑤页项数 = %d，应为 7' % len(items))

print()
print('【4】N7 与 AC-13 的对撞是否两边都写了')
print('  N7 豁免句：', cnt(new, '14 日内的执行记录不计入 200 MB 容量回收范围'), '处')
print('  AC-13 前提句：', cnt(new, '本承诺的前提 = N7'), '处')

print()
print('【5】H3 允许集表述是否自洽（不得再有「组 B 不在允许集」）')
print('  含「组 B 本不在 H3 允许集内」：', cnt(new, '组 B 本不在 H3 允许集内'), '（应为 0）')
print('  含「AC-08 组 B 在集内、非例外」：', cnt(new, 'AC-08 组 B 在集内、非例外'), '（应为 ≥1）')
if cnt(new, '组 B 本不在 H3 允许集内'):
    fail.append('H3 失实表述未清除')

print()
print('【6】AC 编号完整性 + 变更范围（v3.6 → v3.7）')
def ac_blocks(lines):
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

bo, bn = ac_blocks(old), ac_blocks(new)
print('  v3.6 AC %d / v3.7 AC %d；编号一致 %s' % (len(bo), len(bn), sorted(bo) == sorted(bn)))
changed = [k for k in sorted(bn) if '\n'.join(bo.get(k, [])) != '\n'.join(bn.get(k, []))]
print('  本轮变更的 AC：%s' % changed)
allowed = {'AC-04', 'AC-08', 'AC-09', 'AC-13'}
extra = [c for c in changed if c not in allowed]
print('  越界（应为空）：%s' % extra)
if extra:
    fail.append('AC 越界：%s' % extra)

print()
print('=' * 74)
print('结论：%s' % ('全部通过' if not fail else '有 %d 项需处理' % len(fail)))
for f in fail:
    print('  -', f)
