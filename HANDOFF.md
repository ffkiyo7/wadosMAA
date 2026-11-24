# 交接说明（2026-11-24，北京时间）

## 现在的状态

- 解耦与 iOS 规划的 Phase 0～3 已全部完成；Phase 4 代码已部署，等真机验收（见下）。11-24 09:52 生产切线，线上运行根目录是 `~/.wados-maa`，细节见 `docs/specs/P3_IOS_APP_AND_CUTOVER.md`「当前进度」。
- 常驻进程：LaunchAgent `io.github.ffkiyo7.wados-maa.daemon`（调度器 + HTTPS API，端口 18170）和 `io.github.ffkiyo7.wados-maa.cloudflared`（隧道 `maa.luxraykit.com`）。
- 切线后线上首场 `2026-11-24-am-095250` 跑通，Bark 战报送达。iPhone 和 Mac App 都连着线上。
- `~/.hermes`：MAA 的 cron 已停，按钮已删，`scripts/maa_*.py` 是拒绝桩；17 条非 MAA cron、`ai.hermes.gateway` 照常跑。
- 代码：`dev` = `main`，两个 worktree 都干净；**还没 push**。
- 11-24 核对：maa-remote 935 个单测通过，ruff、pyright 0 报错；`shared` 21 个测试通过；iOS、Mac App 编译通过。

## 接下来做什么

1. **Phase 4 验收**（`docs/specs/P4_AUTO_RESIGN_AND_P2.md`「当前进度」）：代码 11-24 13:52 已部署。
   - 真机续签：11-24 23:47 手动跑通，有效期到 12-01 23:47，新版 App 已装。自动续签 11-29 23:47 窗口打开后看 `maa_ios_resign.py status`。
   - 快捷指令：11-24 已建好，手动运行回 `not_due`。11-29 窗口打开后回家时看 `last_trigger` 是否为 `shortcut`。
   - 证书轮换演练：11-25 00:00 通过，App 无需重新配对。
   - 还要在真机上走一遍设置页 P2（高级配置、仓库对表开关）。
   - 全部通过后勾 S4-5 清单。
2. **抄作业导航通用化**（用户 11-24 确认要做，等放行）：
   - 「进度未知」不要当成「没通」去补前置关。手动轮直达目标区域，自动轮停下并说明原因。
   - 区域入口识别别再靠 `ZONE_OCR_TILES` 固定裁剪，改成通用方案。
3. **11-09 评审还剩的**（`docs/REVIEW_2026-11-09.md`）：
   - 台前调度暂停（#62）真机长期有效的话，删掉旧救援补丁：`front_finder`、`window_shelved`、`winmove` 挪屏、`SCREENCAP_SETTLE_*`，以及对应配置和不变量。
   - P2 第 12 项：逐环节执行 + 统一恢复梯子 + 认画面。
   - 第 13 项（调度搬出 Hermes）已由内置调度器完成，不用再做。
   - 小尾巴：
     - 每场的基建/公招/商店/领奖开关（现在单场只能开关刷理智）。
     - 三个「定时场前 N 分钟」合并成一个。
     - `runs/index.jsonl` 不收锁冲突场、Depot、资源更新。
     - 抄作业已写 `progress.json`，可评估删掉 `RunStageParser`。
     - 清理 `gui/ExportOptions.plist`。
4. 要不要 push `dev` / `main`，由用户决定。

## 已知问题

- `deploy.py` 不带 `--standalone`（也没设 `WADOS_MAA_HOME`）时仍走 Hermes 模式、往 `~/.hermes` 写。部署一律按 `AGENTS.md` 带 `--standalone`。
- 开发副本 `maa-remote-devhome` 的守护进程也配的 18170 端口，线上在跑时不能同时起。
- 两套 Python：守护进程用 `~/.local/bin/python3`；Mac App 自动挑解释器时会挑到 `~/.hermes/hermes-agent/venv/bin/python`（`RemoteConfig.autoPython`）。现在能跑，以后删 Hermes venv 时这里要改。
- Discord 代码还在各脚本里（没 token 就跳过）。要不要整块删，等 Phase 4 之后再定。

## 回滚

- 切线备份：`~/.wados-maa/backups/cutover-20261124T095249/`。
- 一键回滚（会停新 LaunchAgent、还原 `~/.hermes` 的脚本、按钮、5 条 MAA cron 和 Mac App 偏好，`~/.wados-maa` 原样保留）：

  ```bash
  python3 ~/Developer/wados-maa-deploy/maa-remote/daemon/cutover.py --rollback ~/.wados-maa/backups/cutover-20261124T095249
  ```

- 单次部署的备份：`~/.wados-maa/backups/maa-setup/<时间戳>/`。
