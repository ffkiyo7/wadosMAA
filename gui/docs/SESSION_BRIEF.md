# 开发会话简报：Wado's MAA（S1–S6）

> 2026-11-06 写给新开的开发会话（opus，high）。当时新会话开在 `~/Developer/forks/MaaMacGui`，第一句话说「按 docs/SESSION_BRIEF.md 开工」即可。

## 现在的位置（2026-11-07 合仓后）

前后端已合成一个仓库 `~/Developer/wados-maa`（远端 `github.com/ffkiyo7/wadosMAA`），说明以根目录 `AGENTS.md` 为准：

- `gui/`：本 fork；`maa-remote/`：maa-remote。平时在 `dev` 分支提交，`main` = 线上已部署版本。
- 合仓时改写过自有提交（去掉 Claude 署名），**旧文档里的提交号如果查不到，到旧仓库 `~/Developer/forks/MaaMacGui`、`~/Developer/personal/maa-remote` 查**。
- 开发副本 `~/Developer/forks/maa-remote-devhome`：`scripts` 软链到 `~/Developer/wados-maa/maa-remote/scripts`。
- Release 构建输出：`~/Developer/forks/wados-maa-build/<名字>`（`-derivedDataPath`），不在仓库里。

下面「当前现场」「工作位置」是 2026-11-06 开工时的情况，只作历史记录。

## 背景

用户要把官方 Mac GUI（MaaMacGui）fork 成「Wado's MAA」，接管自己的明日方舟自动化项目 maa-remote 的日常配置和手动运行。maa-remote 跑在 macOS + PlayCover + maa-cli 上，由 Hermes 网关的 cron 和 Discord 驱动。

要做成的样子：

- **一键长草**：走 maa-remote 的日常执行路径，GUI 里能临时调关卡和环节。
- **自动抄作业**：放在自动战斗页，流程是「选关 → 预览候选 → 自动选中 → 点『确认开打』」。
- **配置**：全部配置项都能在 GUI 里调，并和 Discord 同步。状态只有一份，就是 maa-remote 的状态文件。
- **更新源**：钉在 maa-cli。fork 用弱链接 + rpath 直接用 maa-cli 那份 MaaCore（`~/Library/Application Support/com.loong.maa/lib`）。
- **降级开关**：一个都不提供。不碎石、只吃临期药、不借助战、不忽略练度。
- **肉鸽**：用上游的。maa-remote 自己的肉鸽整套删掉。
- **外观**：Liquid Glass 外壳，背景图可自定义，最低支持 macOS 26。
- **签名**：用 `Apple Development: ffkiyo7@gmail.com`，免费账号，不做公证。

全部决策（K1–K20）、现场摸底和分步都在 `docs/PLAN_MACGUI.md`。两份 spike 报告和推荐改法的 diff 在 `docs/spikes/`。

## 当前现场

- **cron**：maa-remote 的 6 条 cron 已全部暂停。暂停期间没有日常，Core 和资源也不会自动更新。Hermes 网关还在运行，Discord 的手动入口仍然能触发运行。
- **官方 MAA.app**：已移到废纸篓，它的配置目录保留。
- **fork**：`~/Developer/forks/MaaMacGui`，分支 `remotectrl-supported-dev-1106`，基于上游 `b2c99a8`。远端只有 `upstream`，没有 origin。
- **maa-remote**：`~/Developer/personal/maa-remote`，在 main 上，工作区干净。线上 `~/.hermes/scripts/` 和仓库一致。
- **本机**：macOS 26.6、Xcode 26.6，maa-cli v0.7.5，Core v6.21.4。

## 任务

按 `docs/PLAN_MACGUI.md` 实现 S1–S6。S7（切到线上验收）要用户来做，这次不做。

### 开工前先读

1. `docs/PLAN_MACGUI.md`：全部决策 K1–K20 和分步，以它为准；
2. `docs/spikes/2026-11-06-core-from-maa-cli.md` 和 `docs/spikes/2026-11-06-core-from-maa-cli.recommended.diff`，`docs/spikes/2026-11-06-update-source.md`；
3. maa-remote 的 `AGENTS.md` 和 `docs/DEV_GUIDE.md`。§8 的不变量不能破坏；不变量 #46–#50 跟着肉鸽一起删（K16），删的时候同步改表。

### 工作位置

- **fork**：S1–S6 在 `~/Developer/forks/MaaMacGui` 的 `remotectrl-supported-dev-1106` 分支上改；界面重设计在 worktree `~/Developer/wados-maa/gui`（分支 `claude/redesign-ui-60930c`）上改。
- **maa-remote**（K2）：改动全部在 worktree `~/Developer/wados-maa/maa-remote`（分支 `remotectrl-supported-dev-1106`）里做，已经建好。

  **不许碰** `~/Developer/personal/maa-remote` 的工作区和 main。
- **开发期状态副本**（K1）：
  - 把 `~/.hermes/state/maa/` 和 `~/.hermes/state/agent-book/` 复制到 `~/Developer/forks/maa-remote-devhome/state/` 下；
  - GUI 和它调用的脚本一律带 `HERMES_HOME=~/Developer/forks/maa-remote-devhome`；副本的 `scripts` 软链到 `~/Developer/wados-maa/maa-remote/scripts`；
  - **不要复制 `~/.hermes/.env`**：副本里没有 `DISCORD_BOT_TOKEN`，开发期就不会真的发 Discord，这是故意的。发 Discord 的路径用单测覆盖。

### 顺序

建议按 S1 → S2 → S3 → S5 → S6 → S4 的顺序做，可以按需调整。

S1 有三项 P0，必须在第一次以去沙盒状态启动 App **之前**做完：

- 删掉 Debug 构建每次启动都会删 `<Documents>/resource` 的那段代码；
- Core 的用户目录改成 `~/Library/Application Support/io.github.ffkiyo7.MaaRemoteGui/`；
- 删掉 Sparkle 依赖，以及 `Info.plist` 里的 `SUFeedURL` / `SUPublicEDKey`。

验收一律用 **Release** 构建，Debug 测不出库验证问题。entitlements 要加 `disable-library-validation`。

## 硬约束

- **不碰线上**：
  - `~/.hermes` 只读；
  - 不跑 `deploy.py`（`--check` 可以）；
  - 不恢复、不修改 cron；
  - 不调 Discord API。
- **不碰游戏，也不动共享的 maa-cli 安装**：
  - 不启动、不连接游戏、PlayCover 和 MaaTools（1717 端口）；
  - 不跑 `maa run` / `copilot` / `update` / `install` / `hot-update` / `self update`，也不跑 `brew upgrade`。
- **要开游戏或要更新的验证**（包括 S0c / S0d）：先列出来，问用户要时间，用户同意后再做。到时候的硬约束：
  - 不吃药、不碎石、不借助战；
  - 持有 `run.lock`；
  - 避开北京时间 08:00 / 22:00 前后 30 分钟；
  - 结束后关掉游戏。
- **需要用户在系统里点的事**（授辅助功能权限、在钥匙串里允许签名等）：停下来请用户做。
- **拿不准就停下来问**：可以一次问一批，每条给出选项和推荐。时间一律按北京时间说。
- **提交规范**：按根目录 `AGENTS.md`「Commit message」一节。
- **测试**：
  - maa-remote 每次提交前，在 worktree 根目录跑 `python3 -m unittest discover -s tests`；
  - 动了类型或 except 时，再跑 `uvx ruff@0.17.3 check` 和 `uvx pyright@1.1.414`；
  - 单测必须离线，并且和线上状态隔离（见 DEV_GUIDE §9）。
- **搜索范围**：不要从 `~` 或 `/` 出发搜文件，不碰 `~/Library/Mobile Documents`、`~/Music`、`~/Movies`、`~/Pictures`。

## 完成标准

- S1–S6 都已实现，分别提交在两个仓库的 `remotectrl-supported-dev-1106` 分支上。
- fork 的 Release 构建能用开发证书签名，并在 devhome 副本上跑起来。
- maa-remote 的单测、ruff、pyright 全部通过。
- `PLAN_MACGUI.md` 里的进度同步更新。
- 最后给用户一份汇报：
  - 做了什么；
  - 哪些只做了单测或构建验证；
  - 哪些需要真机，列出 S0c / S0d 和 S7 的验证清单；
  - 哪些需要用户在系统里操作。
