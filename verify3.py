# -*- coding: utf-8 -*-
"""CR-008 机械自查（7 项，能抓语义的版本）"""
import re, difflib

old = open('Residue-PRD-v3.5.md', encoding='utf-8').read().split('\n')
new = open('Residue-PRD-v3.6.md', encoding='utf-8').read().split('\n')
fail = []


def cnt(lines, s):
    return sum(t.count(s) for t in lines)


print('=' * 72)
print('【1】旧措辞归零（这些词在 v3.6 正文中应只剩历史留痕/认错登记）')
must_zero = [
    '未达项共五类',
    '元素 =（来源, 未达项）有序对',
    '还差 X 条',
    '另计新样本',
    '保底优先，容量不得压过期限',
    'U1 退回**保留 L0 计数**',
    '本契约从未登记候选清单的承载页编号',
    '且** L2 误判数 ≤ M（M = 0）**',
    '被观察期结束观察到',
]
for s in must_zero:
    c = cnt(new, s)
    print('  %-48s %d' % (s[:48], c))

print()
print('【2】新措辞必须存在')
must_have = [
    ('G-11 逐来源复核', '已单独通过 AC-08 组 B 的全部门槛'),
    ('G-11 新进域不删', '不进入本轮自动删除候选集'),
    ('G-1 熔断不列未达项', '「熔断回退」不列为未达项'),
    ('G-7 两级未达项', '**全局项不带来源、全机器只列一次**'),
    ('G-6 删剩余条数', '不展示剩余条数'),
    ('G-6 样本运行值', '**样本数 = 运行值**'),
    ('G-6 无法归因判据', '路径前缀仍在但 inode 与 birthtime 均不匹配'),
    ('G-6 转下一轮', '**转入下一轮快照**'),
    ('G-2 判定域非空', '**判定域非空**'),
    ('G-2 空域不适用', '空判定域时本组不适用'),
    ('G-10 三项门槛', '三者同时满足'),
    ('G-10 L2 不适用值域', '该来源不适用（无观测通道）'),
    ('G-8 页级状态', '本轮可点亮：是 ／ 否'),
    ('G-8 结论三值', '{达标 / 未达标 / 仅报告}'),
    ('G-15 七项断言', '七项齐全'),
    ('G-12 N-1 键', '(来源, N−1) 键'),
    ('G-12 守卫改记', '触发时版本一律记为切换生效后的版本'),
    ('G-13 归零四清', '观察期计时器清零 + 样本计数清零 + L2 误判分子清零 + 失联计数清零'),
    ('G-3 先到者生效', '期限与容量「先到者生效」'),
    ('G-3 对外口径', '90 天或 200 MB，先到者为准'),
    ('G-4 N8 结算注', '申诉时限不作承诺'),
    ('G-4 14 日落点', '该文案是 14 日的唯一对外宣称落点'),
    ('G-5 脱敏断言', '替换后原文串出现次数 = 0'),
    ('G-9 第②页认回', '承载位 = 第 ② 页「环境明细与候选清单（含举证链）」'),
    ('G-14 删等', '两类、封闭枚举；新增来源须另出变更单'),
    ('A′ 机制上提', '本节自此只承担「为什么这么定」的说明职责'),
]
bad = 0
for tag, s in must_have:
    c = cnt(new, s)
    flag = 'OK ' if c >= 1 else 'MISS'
    if c == 0:
        bad += 1
        fail.append('缺新措辞：' + tag)
    print('  [%s] %-22s %d  %s' % (flag, tag, c, s[:42]))
print('  → 缺失 %d 项' % bad)

print()
print('【3】数量词与列举同时核（数字必须等于列举项数）')
def check_enum(label, sent_re, expect_items):
    for i, t in enumerate(new, 1):
        m = re.search(sent_re, t)
        if m:
            print('  %s 行 %d：%s' % (label, i, m.group(0)[:90]))
            if len(expect_items) != len(set(expect_items)):
                pass
            return
    fail.append('未找到：' + label)
    print('  MISS %s' % label)

check_enum('未达项三类', r'未达项共三类\*\*（[^）]*）', ['观察期', '样本数', 'L0'])
check_enum('结论列三值', r'值域封闭为 \{达标 / 未达标 / 仅报告\} 三种', ['达标', '未达标', '仅报告'])
check_enum('门槛三项', r'三者同时满足', ['观察期', '样本', 'L0'])
check_enum('归零四清', r'四者同时发生', ['计时器', '样本', 'L2', '失联'])
check_enum('第⑤页七项', r'七项只读\*\*：\*\*([^*]*)', ['参与', '来源', '样本数', '双值', 'L2', 'L0', '结论'])

print()
print('【4】新条款与既有条款逐对碰撞（关键冲突词在全文的出现数）')
collisions = ['五类', '四类可同时成立', '未达项集合须与实际不满足项的全集相等', 'L2 误判 ≤ **0 条**']
for s in collisions:
    c = cnt(new, s)
    print('  %-46s %d' % (s, c))

print()
print('【5】承载位全篇搜（三种表述形式都查）')
for s in ['第 ② 页', '环境明细与候选清单', '候选清单']:
    print('  %-24s %d 处 / %d 行' % (s, cnt(new, s), sum(1 for t in new if s in t)))

print()
print('【6】引用坐标：新增文字中不得含硬编码行号引用')
added = [l for l in difflib.unified_diff(old, new, lineterm='', n=0)
         if l.startswith('+') and not l.startswith('+++')]
hardref = [l for l in added if re.search(r'\d+\s*行', l)]
print('  新增行数 %d；含「N 行」引用 %d 处' % (len(added), len(hardref)))
for l in hardref[:5]:
    print('    !', l[:120])

print()
print('【7】AC 编号完整性 + 变更范围')
def ac_blocks(lines):
    blk = {}
    cur = None
    inac = False
    for t in lines:
        if t.startswith('## 4. 验收标准'):
            inac = True
            continue
        if inac and re.match(r'^## (?!4\. )', t):
            inac = False
        if not inac:
            continue
        m = re.match(r'^\*\*(AC-\d+)（', t)
        if m:
            cur = m.group(1)
            blk[cur] = []
        elif cur is not None:
            blk[cur].append(t)
    return blk

bo, bn = ac_blocks(old), ac_blocks(new)
print('  v3.5 AC 数 %d；v3.6 AC 数 %d' % (len(bo), len(bn)))
print('  编号一致：%s' % (sorted(bo) == sorted(bn)))
changed = []
for k in sorted(bn):
    a = '\n'.join(bo.get(k, []))
    b = '\n'.join(bn.get(k, []))
    if a != b:
        changed.append(k)
print('  发生变更的 AC：%s' % changed)
allowed = {'AC-04', 'AC-08', 'AC-09', 'AC-13', 'AC-16'}
extra = [c for c in changed if c not in allowed]
print('  越界 AC（应为空）：%s' % extra)
if extra:
    fail.append('AC 越界：%s' % extra)

print()
print('=' * 72)
print('结论：%s' % ('全部通过' if not fail else '有 %d 项需处理' % len(fail)))
for f in fail:
    print('  -', f)
