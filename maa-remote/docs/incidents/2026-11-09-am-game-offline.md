# 早场整场 GameOffline：游戏没登录上

- 日期：2026-11-09
- 一句话：「获取网络配置失败」弹窗点确认不会重拉配置，只有重启进程才行
- 相关不变量：#61
- 现行机制：DEV_GUIDE §4「恢复策略」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§0.5「游戏没登录上」**

**游戏没登录上**（2026-11-09 早场，`PLAN_GAME_OFFLINE.md`）是另一类，窗口和截图都正常：
游戏一开就弹「获取网络配置失败，请重新登录」，maa-cli 每认出一次弹窗打一行 `GameOffline`。
MaaCore 的 StartUp 点确认 6 次仍报 Completed，其余任务撞上弹窗就 `Stop`（Mall / Award 照样报
Completed）。点确认不会让游戏重新拉配置，只有重启进程才会。`never_logged_in()` 三条都满足
（StartUp 段撞过弹窗、紧接着的那条任务链也撞上、日志里没有任何作战 / 掉落 / 基建 / 公招进展）时，
`run_maa_resilient()` 等 `offline_retry_delays`（默认 120s、300s）→ 写一行 `conf_probe()` 连通性
探测 → `restart_game()` → 摆窗 → 整场重跑，默认最多 `offline_retry_limit` 2 次。死掉那一趟的输出
**不交给战报**（只留我们自己的说明，现场在日志文件里）。放弃时说明里带 `OFFLINE_GAVE_UP`，补跑跳过
（`OFFLINE_SKIP_NOTE`）。战报里撞上 `GameOffline` 的任务一律「❌ 未完成（游戏掉线）」
（`offline_tasks()`，流式段按顺序和汇总的 `[名字]` 配对）；登录后才掉线的不重开，只如实报红。
