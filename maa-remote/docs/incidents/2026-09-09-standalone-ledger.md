# 手动抄资源本把当期活动账本归档掉

- 日期：2026-09-09
- 一句话：空 `activity_key` 让 `ensure_ledger()` 归档活动账本再新开，通关记录散进归档文件
- 相关不变量：#52
- 现行机制：DEV_GUIDE §5.5「本地作业记账」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§5.5「本地作业记账」非活动关**

- **非活动关（资源本 / 主线）另有一份 `ledger-standalone.json`**（四期步骤 5 修的线上隐患）：
  手动抄 `CE-6` / `1-7` 时 `start_copilot_search()` 写的 `activity_key` 是**空串**，
  worker 照样 `ensure_ledger("")`。原来这一步见 key 不同就把当期活动账本归档、新开一份
  空的，下一 tick watcher 再归档回来——真实通关记录就这样散进归档文件。现在
  `ledger_path(activity_key)` 决定落点：空 key → 独立账本，**永不归档、永不新开活动账本**；
  worker 必须拿同一个 key 算出的路径去 `save_ledger()`，否则记完账会把独立账本写回活动账本。
  独立账本不参与自动排轮（自动只跑活动关），种子也永远种不进去（前缀不是 `SR`）。

---

**原文出处：§8 不变量 #52**

| # | 不变量 | 落点 |
|---|---|---|
| 52 | **空 `activity_key` 永远不动活动账本**：非活动关（资源本 / 主线）的记账落 `ledger-standalone.json`，`ensure_ledger("")` 既不归档也不新开活动账本，`ledger_path()` 与 `ensure_ledger()` 必须拿同一个 key 算落点。原来空 key 会把当期账本归档 + 新开空账本，下一 tick watcher 再归档回来，真实通关记录散进归档文件 | `maa_copilot.ledger_path()` / `ensure_ledger()` + `maa_copilot_worker._batch_run_locked()` + `LedgerTests.test_a_non_activity_stage_never_archives_the_running_ledger` / `CopilotBatchExecutionTests.test_a_non_activity_round_writes_only_the_standalone_ledger` |

---

**原文出处：§10 排障表这一行**

| 症状 | 先看 |
|---|---|
| 手动抄了一次资源本，活动记账好像丢了 | 先看 `copilot/` 下是不是多了 `ledger-<key>.json` 归档。这是 2026-09-09 修掉的隐患（不变量 #52）：空 `activity_key` 会把当期账本归档。修完之后非活动关记在 `ledger-standalone.json`，活动账本不受影响 |
