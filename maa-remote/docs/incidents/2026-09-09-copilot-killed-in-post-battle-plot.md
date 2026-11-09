# 抄作业打完直接杀游戏，停在战后剧情，代理指挥锁着

- 日期：2026-09-09
- 一句话：SR-8 三星但没进结算页，早场日常 `UsePrts` 点不亮空跑；由此加了战后收尾
- 相关不变量：—
- 现行机制：DEV_GUIDE §5.5 关键事实 11

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§5.5 关键事实 11**

11. **打完不能直接杀游戏——先跳剧情、回主界面**（2026-09-09）。SR-8 两次抄作业
   （`runs/2026-09-08-copilot-9e14e500ac25`、`2026-09-09-copilot-fda56c1811ba`）
   `Copilot Completed` 之后 5 秒 `close_everything()` 就 `maa closedown`，两张收尾截图
   都停在**战后剧情页**（右上「自动 OFF / 跳过 ▶」）。结果：游戏里 SR-8 三星，
   **代理指挥却锁着**，早场日常点了 10 次 `UsePrts` 点不亮、`Fight Error` 空跑。
   asst.log 复核过两场都没借助战（Copilot 参数无 `support_unit_usage`，8 个位置全是
   自己的干员；`BattleQuickFormationRole-Support` 是职业筛选「辅助」页签）。
   **09-09 08:59 真机验证**（`runs/2026-09-09-copilot-71bfa8404dbe.log`）：顺序是
   战斗结束 → 剧情 → 结算页；剧情跳过成功、游戏进到结算页、代理指挥解锁，虽然最终
   没回到主界面。**界线是结算页，不是主界面**——昨天被杀在剧情里，结算页从没出现过，
   所以今天剧情还重放了一遍（游戏没记成已看）。
   现在 `_batch_run_locked()` 对每个进过战斗的条目（`outcome != "nav"`）调
   `settle_after_battle()`：隔离 `MAA_CONFIG_DIR` 里跑 `copilot-settle.toml` 两段 Custom
   ——`["CopilotSettleSkip", *HOME_TASK_NAMES]`（在剧情页走跳过链，在详情页直接回家）
   + `HOME_TASK_NAMES`。`CopilotSettleSkip` / `CopilotSettleSkipConfirm` 派生自上游
   `SkipBattlePlot` / `SkipBattlePlotConfirm`（`SETTLE_OVERLAY_TASKS`，经 `_isolated_config()`
   的 `overlay_tasks` 只写临时 tasks.json），差别只有确认后的 `next` 清空：上游接的
   `EndOfPlot` 在跳过后直接进结算页时永远等不到，真机白等了 20 轮才 Error。
   **两段任一 `Completed` 即算成功**；两段都 Error 才在战报和账本 `detail` 带一句中性的
   「战后未回到主界面」，**不改胜负**。`copilot_settle_timeout` 默认 240s。
   结算页本身**不处理**：多关连抄时下一关的 `StartUp` 自带 `EndOfAction → ClickCorner`
   （03:06 SR-5 → SR-6 的日志），最后一关停在结算页被关掉已验证无害。若哪一关结算页
   之后还有第二个弹窗 / 剧情才需要派生 `EndOfAction`——注意上游 `ClickCorner.next` 里
   有 `StartButton2`，照搬会再开一局。
