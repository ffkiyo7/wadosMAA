# 活动监控 cron 暂停，抄作业页一直列上一期活动、新活动整页 no_nav

- 日期：2026-11-07
- 一句话：当期活动只认 `activity_watch.json`，游戏数据刷新排在暂停判断之后
- 相关不变量：—
- 现行机制：DEV_GUIDE §3「抄作业卡」、§3.5、§5.5「本地作业记账」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§3「抄作业卡」**

**「当期活动」以 MaaCore 活动缓存为准**（`maa_plan_card.current_activity_key()`，2026-11-07）：
读 `StageActivityV2.json`（`config.maa_activity_cache`，默认 `~/Library/Caches/com.loong.maa/`）里
**此刻开放**的 SideStory，key 拼法与 watcher 的 `activity_target()` 一致（`Tip|前缀`，复刻条目
`SSReopen` 的前缀从它的关卡里取，同时开放几期取开始最晚的）；缓存读不出来才退回
`activity_watch.json` 的 `activity_key`。原来只认 watch，而 watch 只有活动监控 cron 在跑时才更新——
cron 暂停期间抄作业页一直列 10 月的 YW。抄作业卡、`copilot stages`、`copilot find` / `preview` /
`mark-cleared` / `unmark` 都走它；watch 的逐关失败记录（`stage_state`）只在 watch 的 key 与当期一致时才用。
watcher 自己仍按 `maa activity` 认活动，worker 开打前也按 `maa activity` 复核（两者 key 拼法相同）。

---

**原文出处：§3.5 游戏数据刷新**

**游戏数据刷新不受「暂停自动作业」影响**（2026-11-07）：`copilot/gamedata.json` 也是抄作业页
（`copilot stages`）和手动抄作业判「能不能导航」的依据。原来刷新排在暂停 / 停排判断之后，
线上自动作业从 10-19 暂停，TL 上线一周游戏数据里还没有它，抄作业页整页 no_nav。
**所以活动监控 cron 要一直开着**；不想让它开游戏，用「暂停自动作业」（`copilot auto off`），
而不是暂停 cron。暂停时换活动的「🆕 已上线」通知会写明不会自动排轮。

---

**原文出处：§5.5「本地作业记账」归档接回**

- `activity_key` 变了（新活动 / 复刻）→ 旧账**归档**成 `ledger-<安全化的 key>.json` 再新开
  （`ensure_ledger()`）。归档而不是删：回头想知道上个活动抄到哪了只有这份说得清。
  **切回一期归档过的活动就接回那份归档**（2026-11-07）：当期活动有 watch 和 MaaCore 缓存两个来源，
  两期同时开放时可能认出不同的 key；原来来回切一次，新开的空账就会把归档盖掉。
