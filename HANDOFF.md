# 交接说明（2026-11-06 18:15，北京时间）

## 这次做完的事

- maa-remote 的 5c6b9d5 已部署到线上 `~/.hermes`。本地 `main` 已快进到 5c6b9d5，**还没 push**。727 个单测通过，部署后 `--check` 全过。
  `hermes gateway restart` 已执行，Discord 上的 maa-operator 技能现在是 4.2.0（去掉了肉鸽）。
- 线上两个肉鸽旧脚本已挪到备份目录。开发副本里那条残留的 dispatched 手动场已删除。
- GUI 发起的手动场真机跑通：token `3dd4e4b513ea`，关卡 TL-9，17:59:06 开跑、18:13:18 结束，`status=success`。
  - 刷理智 5 次，结束时理智 11/208，掉落电极单元 ×5。
  - 基建、公招、信用商店、领奖都完成；剿灭本周已满，按设计跳过。
  - 截图确认回到了主页（识别到 8/9 个标识），Discord 战报已发（thread `1568203094716584032`）。
- 目录已整理：两个 worktree 都在 `~/Developer/wados-maa/` 下面（见 `AGENTS.md`）。
  开发副本的 `scripts` 软链已改指到新路径。

## 回滚

- 部署前的快照：`~/.hermes/backups/maa-predeploy-20261106T175447/snapshot.tgz`，在 `~` 下解压。肉鸽旧脚本在同一目录的 `retired-scripts/`。
- `deploy.py` 自己的备份：`~/.hermes/backups/maa-setup/20261106T175457/`。
- 回滚步骤：解压快照，删掉线上的 `maa_schedule.py`、`maa_settings.py`、`maa_upstream.py`，再执行 `hermes gateway restart`。

## 需要用户做或决定的

1. App 留在线上还是切回开发。切回开发要先退出 App，执行 `defaults delete io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome`，再重开。
2. 要不要 push：maa-remote 的 `main` 和 GUI 分支都还没 push。
3. 线上 7 条 MAA cron 部署前后都是暂停的，部署没碰。config 里 `session_schedule` 两场都是「开」，
   所以 App 场次页会显示「与配置不一致（暂停）」。在 GUI 里拨开关会恢复 cron。
4. 这场跑通了，可以按 DEV_GUIDE §7.1 把 `config/verified_versions.json` 的 MaaCore 改成 v6.21.4，单独提交一次。

## 发现了但没修的问题

1. GUI：切环境后 `RemoteStore.startWatching()` 还在监听旧的 `HERMES_HOME`。它只在 `ContentView.task` 里调一次，而且有 `guard sources.isEmpty`，
   所以首页的锁状态和最近一场最多晚 60 秒才更新。修法：`hermesHome` 一变就 `stopWatching()`、`startWatching()`、`reload()`。
2. GUI 拉起 `maa_action.py` / `maa_daily.py` 用的是 `/usr/bin/python3`（Xcode 自带的 3.9），cron 用的是 hermes venv 的 3.11。这次能跑，但是两套解释器。
3. `last_run.json` 合并写的时候会留着上一场的旧字段。这场跑完后，顶层仍然是 `stage=YW-EX-3`、`ok=false`、`skip_reason=emulator_busy`，
   但 `status=success`、`summary` 和 runs 快照都对。GUI 如果读 `ok` 或 `stage` 会显示错。
   另外，这场快照里的 `plan.stage_source` 是 `discord`，可它其实是 GUI 发起的。
4. GUI 文档 `docs/SESSION_BRIEF.md` 和 `docs/PLAN_MACGUI.md` 里还写着旧路径（`.claude/worktrees/redesign-ui-60930c`、`forks/maa-remote-dev`）。
5. 开发副本 `maa-remote-devhome` 没有 `.env`（缺 `DISCORD_BOT_TOKEN`），所以在开发环境里 `run local` 起不来。
7. GUI 首页「手动开一场」跑完后还显示「日常·手动（自 17:59）正在用游戏」，「开始这一场」按钮也一直是灰的。
   原因：这行字读的是 `RunData.choices.busy`，也就是 `run choices` 返回的 `busy`。`choices` 只在两个时候加载：Shell 的 `.task`（App 启动时）和 `TodayPage.start()` 末尾。
   点「开始」后那次重新加载时子进程正拿着锁，`busy` 就被缓存下来，之后再也不刷新（`RemoteStore.reload()` 不碰 `RunData`）。
   当时线上 `run.lock` 早已放开（18:13 清空，没有持有者）。修法：`store.lockHolder` 或 `lastRun` 一变就重新 `loadChoices()`，或者 `busy` 直接用 `store.lockHolder`。
   临时办法：重开 App。
8. GUI 跑完没有任何反馈（没有弹窗，也没有通知），首页只留着派发时的那句回执。可以在 `last_run.json` 的 `status` 从 running 变成终态时弹一下战报摘要。
9. GUI 顶部状态条没有显示「上次成功」的时间。可以取 `last_run.json` 的 `finished_at` 和 `status`（注意第 3 条：别读 `ok`）。
6. 旧 session「Wado's MAA 新界面 SwiftUI 实现」和「maa-remote-dev-fork」的工作目录已经搬走了，不要再续这两个 session，从 `~/Developer/wados-maa` 开新的。
