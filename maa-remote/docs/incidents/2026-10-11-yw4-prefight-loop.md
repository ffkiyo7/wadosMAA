# 自动作业空转 17 轮：森空岛过期，YW-4 反复开游戏又关

- 日期：2026-10-11
- 一句话：刷新失败沿用过期缓存照排、开打前环境故障不记账，永远到不了当日上限
- 相关不变量：#55
- 现行机制：DEV_GUIDE §3.5、§5.5

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§8 不变量 #55**

| # | 不变量 | 落点 |
|---|---|---|
| 55 | **森空岛读不到就不自动排轮**（2026-10-11 改写：以前「刷新失败沿用缓存照排」，过期一个月的缓存里没有当期活动的 zone 进度，YW-4 没解锁也被排上）。**开打前的环境故障**（森空岛读不到、理智消耗查不到、开机 / ADB 炸了且一关都没进）worker 写进这一轮的 `prefight_error`，watcher 按北京日计数（`activity_watch.json` 的 `prefight_failures`），达到 `auto_copilot_max_prefight_failures_per_day`（默认 2）当天停排、只发一条——它们**不记账**，不另记就永远到不了 `daily_cap`。「理智不够」不是环境故障，不计数。「暂停自动作业」开关在 `copilot/auto_pause.json`：只管 `source == activity-watch` 的轮，暂停时作废 `scheduled` / `queued` 的一轮，**不中断正在打的那一关**、下一关开打前停；`copilot auto on` 同时清掉当天的开打前停排。按钮 custom_id 固定为 `hermes:btn:maa-copilot:auto:off|on`，不受按 token 清扫的影响 | `maa_activity_watch.run_once()` / `_count_prefight_failure()` / `_prefight_blocked()` + `maa_copilot_worker.PrefightError` + `maa_action.copilot_auto()` + `ActivityWatchTickTests` / `CopilotBatchExecutionTests.test_a_prefight_environment_failure_is_marked_on_the_round` / `CopilotAutoPauseCommandTests` |

---

**原文出处：§10 排障表这一行**

| 症状 | 先看 |
|---|---|
| 自动作业每 15 分钟开一次游戏、几十秒就关，同一关反复排（2026-10-11 YW-4 空转 17 轮） | 开打前的环境故障（多半是森空岛过期）。现在会被不变量 #55 截住：`activity_watch.json` 的 `status=blocked` + `blocked_reason` / `prefight_failures` 是答案；修好后说「恢复自动作业」立刻解除，否则次日自动恢复 |
