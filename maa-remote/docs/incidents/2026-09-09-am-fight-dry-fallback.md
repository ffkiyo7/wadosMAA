# 早场主关空跑失败，后备关白挂到晚上

- 日期：2026-09-09
- 一句话：SR-8 代理指挥没解锁、刷理智一颗没花，`farming_fallback_stage` 没人用；由此加了后备关补跑
- 相关不变量：—
- 现行机制：DEV_GUIDE §4「恢复策略」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§11 第 13 条末尾**

    - **主关空跑失败 → 改刷后备关**（2026-09-09 早场加）：SR-8 的代理指挥没解锁，
      `[刷理智]` 段 `Error` 收尾、一颗理智没花，MaaCore 接着把基建 / 公招 / 商店 / 奖励
      跑完了，`farming_fallback_stage = SR-7` 却没人用，94 理智白挂到晚上。现在
      `execute()` 在 `return_code != 0` 且 `fight_failed_dry()`（段里没有
      `Fight <关> n times`、没有掉落、`[刷理智·续]` 没跑过）时调 `_fallback_fight_run()`：
      `fallback_fight_plan()` 只保留 Fight、`annihilation = False`、块名用
      `FARMING_TASK_NAMES[1]`（战报自然落在「刷理智·续」那一行，不带 drops）。预算同样
      从 `maa_run_timeout` 里扣，剩余不足 `fight_fallback_min_seconds`（默认 300s）就跳过，
      `fight_fallback_on_error: false` 整体关掉；日志落在 `runs/<date>-<phase>-fallback.log`
      （`last_run.salvage_log` 复用同一个字段）。打了几批之后才 Error 的**不补**——
      那是别的问题。测试：`FightFallbackTests`（含 09-09 早场真实汇总段回放）。
