# 部署用仓库种子盖掉线上 `activity_stages`

- 日期：2026-09-02
- 一句话：部署把正确的 `[]` 换成一个月前 TO 活动的关卡，直到下一次 watcher 才清掉
- 相关不变量：#19、#25
- 现行机制：DEV_GUIDE §7 第 3 步

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§7 第 3 步**

3. **状态的部署策略不同**（`deploy_state()`，`deploy.py`）：
   - `config.json`：**逐键合并**，仓库的键覆盖同名键，本地新增键保留。
     **例外是三个运行时缓存键**（`deploy.PRESERVED_RUNTIME_CACHE_KEYS`，不变量 #25）：
     `maa_core_version` / `maa_cli_version`（计划卡的版本探测写）和
     `activity_stages`（活动 watcher / 计划卡写）——**线上已有值就一律保留**，
     种子只在线上还没有这个键时（首次部署）当兜底。
     它们是运行时缓存，不是仓库拥有的配置；让种子赢就等于每次部署都把
     `PLAN_NAV_GATE.md` A-3 修掉的那种过期又造一遍
     （2026-09-02 实际发生过一次：部署把正确的 `[]` 换成了一个月前 TO 活动的关卡，
     直到下一次 watcher 才清掉）。
     同时丢掉已废弃的 `resource_update_interval_days`。

---

**原文出处：§8 不变量 #25**

| # | 不变量 | 落点 |
|---|---|---|
| 25 | `state/config.json` 里**由线上进程写回的运行时缓存键**（另外，`config_meta` 里记过的用户改动也保留线上值，见 §6.2）（当前 `maa_core_version`、`maa_cli_version`、`activity_stages`）必须列入 `deploy.PRESERVED_RUNTIME_CACHE_KEYS`：线上已有值一律保留，仓库种子**只在首次部署时兜底**。**新增此类键时必须同步加进这个元组**，否则每次 `deploy.py` 都会用种子盖掉线上真值（2026-09-02 已实际发生过一次） | `deploy.PRESERVED_RUNTIME_CACHE_KEYS` / `deploy_state()` + `test_every_known_runtime_cache_key_is_preserved_on_deploy`（手工清单比对，漏加即红）、`test_deploy_keeps_live_runtime_caches_and_seeds_only_when_absent` |
