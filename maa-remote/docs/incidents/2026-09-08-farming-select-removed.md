# 删掉计划卡第三个下拉（材料缺口），改成后台自动定关

- 日期：2026-09-08
- 一句话：缺口天天变，下拉只能选关、显示不了缺口；2026-09-09 又改成降级期也自动定关
- 相关不变量：#31
- 现行机制：DEV_GUIDE §3「材料缺口 → 自动定关」

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§3「材料缺口 → 自动定关」开头**

### 材料缺口 → 自动定关（四期步骤 3，2026-09-09 改版）

**这里曾经是第三个下拉（`hermes:btn:maa:farming-select`），已删除。** 删的理由：
材料缺口天天变，而下拉只能选关、显示不了缺口，语义和第一个下拉完全重复。
缺口应该是**后台固定计算**的结果，不是让人去挑的选项。

---

**原文出处：§8 不变量 #31**

| # | 不变量 | 落点 |
|---|---|---|
| 31 | 材料缺口是**后台固定计算**，不是一个下拉（2026-09-08 删掉了原第三个下拉——缺口天天变，下拉只能选关、显示不了缺口，与第一个下拉语义重复）。计算结果由 `apply_auto_stage(result, phase)` 写进当天**那一场**的 `sessions.<phase>.stage`（**同一个字段**：`daily.toml` 只有一条刷理智链，两个字段必然产生「谁赢」的歧义），并打 `stage_source="auto"`，连带写下 `farming_drops` 与 `farming_fallback_stage`。**用户在某一场手动选过（`stage_source="discord"`）当天那一场就不许再自动改**，另一场不受影响；`stage_source` 必须留在 `maa_common.PLAN_SESSION_FIELDS` 白名单里，否则点一次「跳过」就把那一场的自动定关冻住。排序指标是**稀缺 / 缺口 / 效率三项加权分**（四期步骤 3，权重在 `config.farming_weights`，和为任意值都归一），不许再叠「库存低于 N 就优先」这类例外规则。**降级期照样自动定关**——2026-09-09 改写：三期不敢改是因为那时排序依据只有手工权重；现在候选集受活动 / 当日开放限制（D5），而且外部掉率数据给了效率与稀缺两项兜底，选出来的关是合理的。降级必须在卡片上标出来并列出原因，而且**降级期不写 `drops` 上限**（缺口是猜的，拿它当「刷够就停」会提前收工）| `maa_farming.farming_result()` / `auto_stage()` / `maa_plan_card.apply_auto_stage()` + `FarmingScoreTests.test_cold_start_uses_manual_weights_but_still_picks_a_stage` / `FarmingAutoStageTests.test_degraded_still_picks_a_stage_and_says_so`
