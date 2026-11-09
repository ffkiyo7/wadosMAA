# 突袭切换真机验证失败

- 日期：2026-09-09
- 一句话：SR-5 普通详情页上根本没有突袭控件，`Custom(ChangeToRaidDifficulty)` 13 秒后 Error
- 相关不变量：#34
- 现行机制：DEV_GUIDE §5.5 关键事实 3、§6.2 `copilot_raid_switch_task`

以下是瘦身前 DEV_GUIDE（2026-11-09）里的原文，原样搬来，没有改写。文中的 §编号指 DEV_GUIDE 的章节（编号未变）。

---

**原文出处：§5.5 关键事实 3**

3. **突袭切换 ❌ 2026-09-09 真机验证失败，功能默认关闭**（现场与下次验证清单见
   `docs/archive/PLAN_PHASE4.md` 的「突袭切换真机验证（2026-09-09）」）。
   Fight 导航停在的是普通难度详情页，要打突袭得先切过去；MaaCore 自己在
   `MultiCopilotTaskPlugin` 里用 `RaidConfirm` / `ChangeToRaidDifficulty`，这里照抄后者，
   跑在与导航同样隔离的临时 `MAA_CONFIG_DIR` 里。实测：SR-5 导航两段都 Completed，
   `Custom(ChangeToRaidDifficulty)` 13 s 后 `Custom Error`
   （`runs/2026-09-09-copilot-5814e6deb762.log` 第 20–32 行）。收尾截图是
   SideStory「月行水上」的普通难度关卡详情页，**整屏没有突袭控件**；上游 ROI
   `[600,610,130,110]`（1280×720，本机 1920×1080 由 MaaCore 自己缩放 ×1.5 →
   `x 900–1095, y 915–1080`）裁出来是纯背景。最可能的根因是**首次开放的 SideStory
   本来就没有突袭难度**（突袭只在复刻活动里有；上游 `tasks/Stages/SR.json` 也没有任何
   突袭变体，`RaidDifficulty-Chapter15.png` / `NormalDifficulty*.png` 是主线章节资产）。
   **`config.copilot_raid_switch_task` 空串 = 突袭功能整体关闭**（不是「跳过切换直接打」
   ——单文件 `maa copilot <uri> --raid raid` 根本不切难度，`is_raid` 只对 `copilot_list`
   的条目有意义，跳过切换打完会把普通难度记成一次突袭通关）。三层落实：
   `maa_clearing.required_modes()` 不产生 `raid` 条目 → worker `_batch_run_locked()`
   拿到 `raid` 条目判 `skipped` → `switch_to_raid()` 直接拒绝。仓库种子是 `""`。

---

**原文出处：§6.2「怎么重新打开突袭」**

#### 怎么重新打开突袭

改 `state/config.json` 的 `copilot_raid_switch_task`，`python3 deploy.py` 生效
（仓库的值会覆盖线上同名键）。两个候选写法：

```jsonc
"copilot_raid_switch_task": "ChangeToRaidDifficulty"   // 现在的默认任务名（09-09 验失败）
```

上游 MaaCore 的 `MultiCopilotTaskPlugin` 其实是**两个任务名并列**当候选跑的
（`RaidConfirm` 先判「已经是突袭」，不是才点 `ChangeToRaidDifficulty`）。想照抄它，
除了改这个键还要把 `scripts/maa_copilot_worker.py` 的 `RAID_SWITCH_TOML_TEMPLATE`
改成能接受列表：

```toml
task_names = ["RaidConfirm", "ChangeToRaidDifficulty"]
```

**启用前必须真机验一关**（命令级清单在 `docs/archive/PLAN_PHASE4.md` 的
「突袭切换真机验证（2026-09-09）」）：日志里 `[切换突袭难度] … Completed`、
收尾截图确实停在突袭详情页、那一趟有 `Copilot Completed`、账本 `stages.<关>.raid`
出现时间戳——四条缺一条就把开关改回 `""`。另外注意：**突袭只在复刻活动里存在**，
首次开放的 SideStory 详情页上根本没有这个按钮，拿它验只会一直 `Custom Error`。

---

**原文出处：§10 排障表这两行**

| 症状 | 先看 |
|---|---|
| 突袭那次总是失败 | 现状（2026-10-19 起）：种子改回 `ChangeToRaidDifficulty`，突袭默认开启。活动关走多作业路径，难度由 `copilot_list` 的 `is_raid` 切，YW-EX-1 / EX-2 突袭真机通过；`switch_to_raid()` 那一趟只剩逐关路径在用。以前默认空串 = **突袭功能关闭**。要重新启用先看 `runs/<date>-copilot-<token>.log` 里 `# raid-switch` 那段有没有 `Custom Completed`；2026-09-09 实测是 `Custom Error`（详情页上根本没有突袭控件），详见 §5.5 第 3 条 |
| 卡上写「✅ 已通（突袭功能未启用）」 | 不是缺陷：`copilot_raid_switch_task` 为空，这一关只按普通难度判通关。想补突袭要先把开关配好并真机验一关（清单在 `docs/PLAN_PHASE4.md`） |
