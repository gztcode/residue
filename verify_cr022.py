#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Residue PRD · CR-022 七条偏差落地校验

背景（CR-022 落地前确立的规则）：
  > **「一个数字 / 一个枚举 / 一个字段序」出现在两处，必须两处同时改 +
  > 机器断言两处一致**。人眼核对一定漏一处。
  —— 这是 R2 五轮评审吃过的亏（CR-009 → CR-021 累计 22 单的共同根因）。

CR-022 变更单 `Residue-CR-022-七条偏差受理.md` 的「三、落点穷举表」给出：
  每个待改原词在 PRD 全文的**精确出现次数**、其中**要改**几处、其中**不改**几处。

本脚本**机器复核那张表**，防止：
  ① 改了源头没改引用点（漏改）；
  ② 不该改的历史留痕被误改（改过头）；
  ③ 新增措辞与 R2 技术方案侧**逐字不一致**（同一事实两处写、两个值）。

用法：python3 verify_cr022.py [PRD路径]
"""
import sys, re, os

def _latest_prd():
    import glob as _g
    cands = sorted(_g.glob('Residue-PRD-v*.md'),
                   key=lambda p: [int(x) for x in re.findall(r'[0-9]+', p)])
    return cands[-1] if cands else 'Residue-PRD-v5.4.md'


P = sys.argv[1] if len(sys.argv) > 1 else _latest_prd()
PLAN = 'Residue-R2-技术方案-v1.6.md'
TXT = open(P, encoding='utf-8').read()
L = TXT.split('\n')
PLANTXT = open(PLAN, encoding='utf-8').read() if os.path.exists(PLAN) else ''

FAIL, OK = [], []

def must(c, m):
    (OK if c else FAIL).append(m)


# ============ 变更清单小节区间（历史留痕行，不算生效正文）============
# ⚠ 区间必须在**下一个 `## ` 标题处**关闭，不能只等下一个「变更清单」标题——
#   否则最后一个变更清单小节会把**其后全部正文**误判为变更清单
#   （v5.4 实测：L736 的 v4.0 变更清单曾吞掉 L736→EOF 共 575 行，
#     使 AC / N7 / M4 等**全部规范正文**被当成「历史留痕」而绕过校验）。
CHANGE_RANGES = []
_i = None
for _k, _ln in enumerate(L):
    if _i is not None and _ln.startswith('## '):
        CHANGE_RANGES.append((_i, _k - 1))
        _i = None
    if _ln.startswith('## 相对 v') and '变更清单' in _ln:
        _i = _k
if _i is not None:
    CHANGE_RANGES.append((_i, len(L) - 1))


def in_change_list(idx):
    return any(a <= idx <= b for a, b in CHANGE_RANGES)


# ============ A 段：旧措辞归零（生效正文命中数必须为 0）============
# 落点穷举表：原词 → (生效正文应剩几处, 变更清单留痕应剩几处)
# 说明：「生效正文应剩 0」指该原词在**规范正文**里必须为 0；
#       若原词本身**不是被替换的对象**（如「内容读取记录数为 0」是保留的判定措辞），
#       则改为断言其**载体指向**已落地。
OLD_TERMS = [
    # (原词, 生效正文期望命中数, 说明)
    ('未取得 Full Disk Access', 0, '偏差 6：文案换口径，生效正文必须为 0'),
    ('一键清除全部采集与日志', 0, '偏差 3：清除范围限定后旧措辞在生效正文必须为 0'),
    ('常驻监听进程退出', 0, '偏差 5：进程级→任务级'),
    ('无常驻事件监听进程存在', 0, '偏差 5：进程级→任务级'),
    ('第 4 档常驻采样进程', 0, '偏差 5：进程级→任务级'),
    ('lsof 因权限受限无法判定别的进程', 0, '偏差 1：第三类 Given 换口径'),
    ('FDA 未授予时该行填', 0, '偏差 6：§6 ⑥ 列文案换口径'),
    ('FDA 未授予态并入既有', 0, '偏差 6：AC-08 组 A 来源项文案换口径（生效正文）'),
    ('另备用例②″ FDA 未授予态', 0, '偏差 6：AC-08 ②″ 用例 Given 换口径'),
    ('同 uid 进程枚举失败时该行填', 1, '偏差 6：§6 ⑥ 列新文案已落地'),
]

print('=' * 68)
print('CR-022 落地校验')
print('PRD: %s' % P)
print('方案: %s%s' % (PLAN, '' if PLANTXT else '  [缺失 · 跳过 B 段]'))
print('=' * 68)

# 判定「生效正文」：排除变更清单登记行
def effective_hits(term):
    out = []
    for idx, line in enumerate(L):
        if term in line and not in_change_list(idx):
            out.append(idx + 1)
    return out


print('\n--- A 段：旧措辞归零（生效正文）---')
for term, expect, why in OLD_TERMS:
    hits = effective_hits(term)
    if expect == 0:
        must(len(hits) == 0,
             'A:%s 生效正文命中数应为 0，实为 %d %s' % (term[:26], len(hits), hits))
        print('  %s %-30s 命中 %d %s' % ('✓' if not hits else '✗',
                                        term[:30], len(hits),
                                        '(预期 0)' if not hits else hits))
    else:
        must(len(hits) == expect,
             'A:%s 生效正文命中数应为 %d，实为 %d' % (term[:26], expect, len(hits)))
        print('  %s %-30s 命中 %d (预期 %d)' % ('✓' if len(hits) == expect else '✗',
                                                term[:30], len(hits), expect))


# ============ B 段：新增措辞与方案侧逐字一致 ============
print('\n--- B 段：新增措辞与 R2 方案侧逐字一致 ---')
NEW_TERMS = [
    ('无法枚举本用户进程', '偏差 6 的新文案'),
    ('L0 未判定（无法枚举本用户进程）', '偏差 6 的 AC-08 来源项文案'),
    ('无常驻采样任务在运行', '偏差 5 的任务级判据'),
    ('contentReads', '偏差 7 的判据载体'),
    ('同 uid 进程的 fd 枚举失败', '偏差 1 的第三类 Given'),
    ('本用户进程无引用', '偏差 4 的文案禁写清单的反向'),
    ('无法枚举本用户进程）', '偏差 6 的 §6 ⑥ 列文案'),
]
for term, why in NEW_TERMS:
    in_prd = term in TXT
    in_plan = (term in PLANTXT) if PLANTXT else True
    must(in_prd, 'B:%s 未在 PRD 落地' % term)
    if PLANTXT:
        must(in_plan, 'B:%s 未在方案侧找到（两侧不一致 → 同一事实两处写、两个值）' % term)
    print('  %s %-32s PRD:%s 方案:%s  (%s)' % (
        '✓' if (in_prd and in_plan) else '✗', term[:32],
        '有' if in_prd else '无', '有' if in_plan else '无', why))


# ============ C 段：七条偏差的「不得误改」护栏 ============
print('\n--- C 段：护栏（不得误改 / 不得放松）---')
GUARDS = [
    # (必须仍然存在的串, 说明)
    ('进程模型标识（单进程 / LaunchAgent / helper / launchd 按需 四类）已登记可查',
     '偏差 5：部署形态枚举不得误改'),
    ('关闭后一个完整定时任务周期内（≥ 下一次每日任务触发）新增采集日志条数为 0',
     '偏差 5：AC-10 可证伪窗口不得放松'),
    ('不删除任何条目、不把「无法判定」当作「无活引用」',
     '偏差 1：AC-14 降级底线不得放松'),
    ('不填 `0 / 0`', '偏差 6：P4「无法判定」不得填 0/0'),
    ('`a` = 门槛项、须为 0', '偏差 4：L0 零容忍不得放松'),
    ('14 日豁免只作用于容量阈值，不作用于 90 天期限', '偏差 2/3：M6 豁免边界不得放松'),
    ('`F` ∩ `P_now` − `C_done`', '偏差 4：M4 判据式不得被改写'),
    ('H = min(30, T)', '偏差 6：门槛规则不得被改'),
]
for term, why in GUARDS:
    hit = term in TXT
    must(hit, 'C:护栏缺失 —— %s' % why)
    print('  %s %s' % ('✓' if hit else '✗', why))


# ============ D 段：变更清单存在且 7 条齐 ============
print('\n--- D 段：CR-022 变更清单登记 ---')
has_hdr = any(ln.startswith('## 相对 v5.3 的变更清单') for ln in L)
must(has_hdr, 'D:缺「相对 v5.3 的变更清单」小节')
print('  %s 变更清单小节存在' % ('✓' if has_hdr else '✗'))
for i in range(1, 8):
    hit = ('偏差 %d' % i) in TXT
    must(hit, 'D:变更清单缺「偏差 %d」' % i)
    print('  %s 偏差 %d 已登记' % ('✓' if hit else '✗', i))


# ============ E 段：CR-022 落地遗漏补正（v5.5）============
#
# 背景：偏差 1（FDA 降为失败后指引）与偏差 6（文案换口径）在 v5.4 落地时
# **未改到位 4 处**（AC-05 Given / AC-05 判定 / §8 无权限 / V5 建议值）。
# 由 B-1 用例基线 + 概念级重扫发现。
#
# **教训**：概念性改动必须按**概念**穷举，不能只按**精确字符串**穷举。
# 原落点表只数了「未取得 Full Disk Access」这个精确串，漏掉了
# 「FDA 作为前置条件 / 判定依据」的其他表述形式。
print('\n--- E 段：CR-022 落地遗漏补正（AC-05 / §8 / V5）---')
REMEDY = [
    # (旧措辞, 期望生效正文命中数, 说明)
    ('Full Disk Access 已授予', 0,
     'AC-05 Given 不得以 FDA 已授予为前置（产品不判 FDA）'),
    ('FDA 未授予时无法可靠枚举别的进程', 0,
     'AC-05 判定的触发条件须为「同 uid 枚举失败」'),
    ('lsof 受限', 0,
     '§8「无权限」三类须与 AC-14 对齐（lsof 已弃用）'),
    ('lsof 检测别的进程会撞 Full Disk Access', 0,
     'V5 建议值的理由不得引用已弃用机制'),
]
for term, expect, why in REMEDY:
    hits = effective_hits(term)
    must(len(hits) == expect, 'E:%s 生效正文命中数应为 0，实为 %d %s' % (term[:30], len(hits), hits))
    print('  %s %-38s 命中 %d %s' % (
        '✓' if not hits else '✗', term[:38], len(hits),
        '' if not hits else hits))

# 补正后的新措辞必须在（否则改了旧句却没写新句）
REMEDY_NEW = [
    ('同 uid 进程 fd 枚举成功', 'AC-05 Given 的新前置'),
    ('同 uid 进程 fd 枚举失败', 'AC-05 判定 / §8 的新触发条件'),
    ('FDA 不解锁', 'V5 的新论据（真实的权限边界）'),
]
for term, why in REMEDY_NEW:
    hit = term in TXT
    must(hit, 'E:%s 未落地（%s）' % (term, why))
    print('  %s %-38s %s' % ('✓' if hit else '✗', term[:38], why))


# ============ 汇总 ============
print('\n' + '=' * 68)
print('通过 %d 项' % len(OK))
if FAIL:
    print('失败 %d 项：' % len(FAIL))
    for m in FAIL:
        print('  ✗ %s' % m)
    sys.exit(1)
print('全部通过：CR-022 七条偏差已按落点穷举表落地，旧措辞归零、新措辞与方案侧逐字一致、护栏未放松')
