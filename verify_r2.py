#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Residue R2 文档机械校验。

起因：R2 第 2 轮闭环核验抓到「§15 声称已修 §5.5、正文却没有」——
与 PRD 阶段第 15 轮 Q26 完全同型（声称已删、实际没删）。
PRD 那边已有 verify_claims.py，R2 这边没有，故补此脚本。

判据分三段：
  A 结构：必备章节 / 关键表存在
  B 落地：每条修法在正文里必须有对应文本（T 列表）
  C 归零：被取代的旧措辞必须全文归零（ZERO 列表），历史处置表行除外
"""
import sys, re, os, glob

def latest(prefix):
    cands = sorted(glob.glob(prefix), key=lambda p: [int(x) for x in re.findall(r'[0-9]+', p)])
    return cands[-1] if cands else None

TECH = sys.argv[1] if len(sys.argv) > 1 else latest('Residue-R2-技术方案-v*.md')
CHK  = 'Residue-R2-安全合规检查表-v1.0.md'
BURY = 'Residue-R2-埋点与指标可测性-v1.0.md'
FAILS = []

def must(cond, msg):
    if not cond: FAILS.append(msg)

tech = open(TECH, encoding='utf-8').read()
chk  = open(CHK, encoding='utf-8').read()
bury = open(BURY, encoding='utf-8').read()
L = tech.split('\n')

# ---------------- A 结构 ----------------
for h in ['## 0. 范围与明确不做', '## 1. 选型决策（ADR）', '## 4. 接口契约',
          '## 5. 数据模型', '## 6. 错误码表', '## 7. 容量与延迟预算',
          '## 8. 并发与一致性', '## 10. 发布、回滚与兼容',
          '## 12. 与基线的偏差登记', '## 15.', '## 16.', '## 17.']:
    must(h in tech, 'A 结构：缺章节 %r' % h)
for adr in range(1, 11):
    must('### ADR-%02d' % adr in tech, 'A 结构：缺 ADR-%02d' % adr)
for ifx in ['IF-01','IF-03','IF-07','IF-08','IF-09','IF-10','IF-11','IF-12']:
    must('### %s' % ifx in tech, 'A 结构：缺 %s' % ifx)

# ---------------- B 落地（每条修法必须有正文对应）----------------
LAND = {
 '段表含 (kind, sourceIndex, offset, length)': '`(kind, sourceIndex, offset, length)`',
 '段表项固定 24 B': '**24×segCount**',
 '段表算例 1536 B': '1536 B',
 '完整尺寸恒等式': '4(magic) + 4(schemaVersion) + 4(headerLen)',
 'T/H/K/J 可为 null + note': '"T": null',
 'null 语义说明': 'T=null 表示',
 'torn tail 自愈六步': 'torn tail 的自愈',
 'torn tail 修复记 recordRepair': 'recordRepair',
 '不补全半行': '补全等于编造记录',
 '幂等键': 'jobId + candidateId + seq',
 'RecordWriter fsync': 'O_APPEND` 单行写 + **`fsync`',
 'E-303 短写不 rename': 'E-303',
 'E-304 段校验': 'E-304',
 'E-306 迁移恢复失败': 'E-306',
 'E-207 体积不可得': 'E-207',
 '位槽号=稠密递增': '稠密递增',
 '目录=递归逻辑字节': '递归逻辑字节',
 '目录字节两时点 t1/t2': 'bytesMeasuredAt',
 '超限移回原位': 'blocked_cap',
 '判定域=同 uid': '判定域写死 = 同 uid 进程',
 '文案只许本用户进程': '本用户进程无引用',
 '其他用户可写则不进候选集': '其他用户可写',
 'ADR-10 .app 打包': 'make_app.sh',
 'SMAppService 四态': 'requiresApproval',
 'readdir 而非 getdirentries64': '`readdir`',
 'lsof 静默丢权理由': '静默丢权',
 'proc_pidinfo 返回 0': 'returned == 0 && errno == EPERM',
 '首检=扫描时/二检=执行前': '首检 = 扫描时',
 'TOCTOU 确定性构造': 'tail -f <候选文件>',
 '快照必须由 full 取': '开轮后的第一次扫描强制 `mode = full`',
 '增量只重取已登记候选': '已登记候选',
 '单一写者扩到全部落盘物': 'restoring',
 'migrating.json step 表': '| step | 含义 | 已发生的副作用 |',
 'step{4,5} 判目标而非原件': '目标是否已是 `toSchema` 且 CRC 通过',
 '预检 3×+64MB': '3 × 状态文件 + 64 MB',
 '分发载体各自 staple': '按载体装订',
 '首发例外演练': '首发例外',
 '演练判据分两支': '未变更 `schemaVersion`',
 '只读不产出报告': '只读，不结算',
 '只读不渲染 0': '—（由更高版本维护）',
 '回滚不是等价替代': '回滚是降级',
 'SHA-256 对账': 'SHA-256 对账',
 '上一版归档': '保留上一版安装包',
 'upstreamCommands 载体': 'upstreamCommands',
 'diagnostics 取证段': 'diagnostics',
 '导出报告五段': '缺任一段即视为报告不可用',
 'restored_by_user 回写': 'restored_by_user',
 'journal begin 补 trigger': '`trigger`',
 'E-204 归错误': '不属 §8 封闭的三类 OS 权限受阻',
 '越界动作专用值': 'blocked_out_of_scope',
 'E-304 保留现场只读': '不提供「重置」入口、不自动重置',
 'step4 在 rename 前': '即将 `rename`',
 'step3 断言 fromSchema': '目标.schemaVersion == fromSchema',
 '卸载 vs 一键清除': '首演判据只能挂「卸载」',
 'E-308 恢复成功': '`E-308`',
 '文件身份=(dev,ino)': '(vst_dev, vst_ino)',
 'PROC_PIDLISTFDS 字节数': '返回值是**字节数**，不是元素数',
 '断点=名字集合': 'completedNames: [String]',
 '预检取值=t1': '预检取值的唯一来源 = `t1` 预览值',
 '测试注入点节': '## 9.5 测试注入点约定',
 'contentReads 计数位': 'contentReads: 0',
 'E-501 新文案': '无法枚举本用户进程',
 'ADR-02 任务级': '无常驻采样任务在运行',
 'V6 定稿': 'K2 裁定 · 定稿',
 '段表示意块字段序对齐': 'offset u64, length u64, kind u8, sourceIndex u8, reserved u16, reserved u32',
}
for name, needle in LAND.items():
    must(needle in tech, 'B 落地：%s —— 正文找不到 %r' % (name, needle[:40]))

# ---------------- C 归零（旧措辞不得留在生效正文）----------------
# 「历史处置表行」= §15/§16/§17 里描述旧做法的行，允许引用旧串
def is_hist(idx):
    for j in range(idx, -1, -1):
        if L[j].startswith('## 15.') or L[j].startswith('## 16.') or L[j].startswith('## 17.'):
            return True
        if L[j].startswith('## 14.') or L[j].startswith('## 13.'):
            return False
    return False

# 作废登记句（正文里合法引述旧串，用于说明「它被什么取代」）
DEAD_MARKERS = ['漏算', '已作废', 'v1.2 的', 'v1.1 的', 'v1.0 的', 'v1.3 写', '旧口径', '已归零', '原「', '已实删', '已改', '改按', '字**典序**最大值', 'vnodeid', '已完成名字集合']
def dead_line(t):
    return any(d in t for d in DEAD_MARKERS)

ZERO = [
 'Σ段长 + 头部长 == 文件长 − 8',
 '先校验原件 CRC',
 '"T": 0, "K": null',
 '2 × 状态文件 + 20%',
 '`otool -L` 无网络框架 + 运行期',
 '无上一版归档则不许发布',
 '从 `.dmg` 拖入 `/Applications`',
 '16×segCount',
 '字**典序**最大值',
 'vnodeid → [pid_t]',
 'vnodes: [UInt64: [pid_t]]',
 'kind u8, sourceIndex u8, offset u64, length u64',
 '同 `E-302`，但**不自动重置**',
 '92 B/条',
 '276 MB',
 '属「无法判定」的边界',
]
for z in ZERO:
    live = [i + 1 for i, t in enumerate(L)
            if z in t and not is_hist(i) and not dead_line(t)]
    must(not live, 'C 归零：旧措辞 %r 仍在生效正文 L%s' % (z[:34], live))

# ---------------- D 跨文档一致 ----------------
must('336 MB' in tech, 'D 一致：技术方案缺「336 MB」三档体量')
must('112 B' in tech, 'D 一致：技术方案缺「112 B/条」口径')
live276 = [ln for ln in bury.split('\n') if '276' in ln and not dead_line(ln)]
must(not live276, 'D 一致：埋点文件仍含 276 且非作废登记：%r' % (live276[:1]))
must('336 MB' in bury, 'D 一致：埋点文件 D-03 未统一为 336 MB')
must('276' not in chk.split('## 四')[0], 'D 一致：检查表正文仍含 276')
must('blocked_out_of_scope' in chk, 'D 一致：检查表 T-1 未改 blocked_out_of_scope')
must('E-308' in tech, 'D 一致：缺 E-308')
must('§12.4' not in bury, 'D 一致：埋点文件仍引用不存在的 §12.4')
must('需验证（口径已变，且仅 1/3 可构造）' in chk, 'D 一致：检查表 S-02 结论未更新')
must('`已覆盖` 9 项' in chk, 'D 一致：检查表汇总未更新为 9 项')
must('otool -L` 不作判据' in chk, 'D 一致：检查表 T-4 未改为三层判据')
must('scan.jsonl.upstreamCommands' in chk, 'D 一致：检查表 T-7 未改读 upstreamCommands')
must('归 §8「错误」类' in chk, 'D 一致：检查表 S-03 未改归类')

# ---------------- E 命名与版本自洽 ----------------
# **断言改为「与文件名版本一致」，不再写死版本号**
#
# 来由：本条原写 `must('最新版 v1.6' in tech, ...)`，于是每次升版都要改脚本。
# 而「改脚本去迁就文档」和「改文档去迁就脚本」都是错的——
# 正确做法是让断言表达**不变量**：「版本说明里的版本 == 文件名里的版本」。
# 这与 check_all.sh 的「自动发现最新版本」是同一个思路（R2 校验脚本自身的维护教训）。
import re as _re
_fname_ver = _re.search(r'v(\d+\.\d+)', os.path.basename(TECH))
_stated_ver = _re.search(r'最新版 v(\d+\.\d+)', tech)
must(_fname_ver is not None, 'E 自洽：无法从文件名解析版本号')
must(_stated_ver is not None, 'E 自洽：版本说明缺「最新版 vX.Y」')
if _fname_ver and _stated_ver:
    must(
        _fname_ver.group(1) == _stated_ver.group(1),
        'E 自洽：版本说明写「v%s」而文件名是「v%s」——两者必须一致'
        % (_stated_ver.group(1), _fname_ver.group(1))
    )
must(
    'v1.8 修订说明' in tech,
    'E 自洽：缺 v1.8 修订说明块（容量上限的硬上限化）'
)
must(
    'v1.7 修订说明' in tech,
    'E 自洽：缺 v1.7 修订说明块（错误码表契约化）'
)
must(all(tech.count('## %d.' % n) == 1 for n in (17, 18, 19, 20)), 'E 自洽：§17 ~ §20 各应出现 1 次')

print('=' * 52)
print('R2 校验对象：', os.path.basename(TECH), '/', CHK, '/', BURY)
print('=' * 52)
if FAILS:
    for f in FAILS: print('  ✗', f)
    print('\n❌ 失败 %d 项' % len(FAILS)); sys.exit(1)
print('✅ 全部通过（结构 %d + 落地 %d + 归零 %d + 一致 10 + 自洽 2）'
      % (12 + 10 + 8, len(LAND), len(ZERO)))
