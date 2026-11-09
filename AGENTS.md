# Wado's MAA

一个仓库，两个子目录：

| 目录 | 是什么 |
|---|---|
| `maa-remote/` | Hermes 上的 MAA 自动化脚本（日常、抄作业、Discord 卡片），Wado's MAA 的后端。部署到 `~/.hermes/scripts/` 才生效 |
| `gui/` | Wado's MAA 界面：纯 maa-remote 前端（SwiftUI）。起家于 MaaMacGui 的 fork，上游功能已全部删掉 |

- 分支：平时在 `dev` 上提交；`main` = 线上已部署的版本。部署用的 worktree `~/Developer/wados-maa-deploy` 固定在 `main`。
- 远端：`origin` = `github.com/ffkiyo7/wadosMAA`；`upstream-gui` = 官方 MaaMacGui，只留作参考（想看上游某个功能怎么做时 `git fetch upstream-gui` 再翻），**不再合并**。不想要可以 `git remote remove upstream-gui`，不影响构建和历史。
- 旧仓库 `~/Developer/personal/maa-remote`、`~/Developer/forks/MaaMacGui` 只读备查，不再往里提交。合仓时自有提交被改写过（去掉 Claude 署名），旧文档里的提交号在新仓库查不到时，去旧仓库查。

开工前先读：`maa-remote/docs/DEV_GUIDE.md`（§8 是不变量，§12 是给 GUI 的接口）、`gui/docs/SESSION_BRIEF.md`、`gui/docs/PLAN_MACGUI.md`。上一次会话的交接说明在 `HANDOFF.md`。

## maa-remote

- 仓库不是运行目录。线上代码在 `~/.hermes/`，改完要部署才生效。排查线上问题以 `~/.hermes/` 里的代码和日志为准；文档和代码对不上时，以线上 `~/.hermes/scripts/` 为准。
- 测试一律在 `maa-remote/` 里跑：`python3 -m unittest discover -s tests`。动了类型或 except，再跑 `uvx ruff@0.17.3 check` 和 `uvx pyright@1.1.414`。
- §8 的不变量不能破坏。

## GUI

- 构建（输出不放仓库里）：

  ```bash
  xcodebuild -project gui/MeoAsstMac.xcodeproj -scheme MAA -configuration Release -derivedDataPath ~/Developer/forks/wados-maa-build/<名字> -skipMacroValidation -skipPackagePluginValidation build
  ```

- 纯前端：不链接 MaaCore、不带 adb、不需要 `disable-library-validation`；所有动游戏、动 maa-cli 的事都调 maa-remote 的命令，本 App 不持 `run.lock`。maa-cli / 资源更新后不用重启 App；启动时不自动更新，首页「游戏资源」卡片提示后由用户点「现在更新」。
- 肉鸽、生息演算、手贴作业、实用工具（公招识别、清点仓库等）已随上游代码删掉；以后要用哪个，先在 maa-remote 加命令，再在界面上接。
- 源码都在 `gui/MeoAsstMac/Remote/`（Xcode 的同步文件夹，新增文件不用改 pbxproj），入口是 `gui/MeoAsstMac/MeoAsstMacApp.swift`。
- 页面设计：避免不必要的辅助标签和文字描述，让界面布局自然地向用户传递信息。

## 两边怎么连起来

- GUI 通过 `HERMES_HOME/scripts/maa_action.py` 调 maa-remote（argv 形式、输出一行 JSON），并直接读 `HERMES_HOME/state/maa/` 下的状态文件和 `run.lock`。
  接口以 `maa-remote/docs/DEV_GUIDE.md` §12 为准。改接口时两边在同一个提交里改、一起验证。
- `HERMES_HOME` 有两个：
  - 线上 `~/.hermes`：真实 cron、Discord、游戏。
  - 开发副本 `~/Developer/forks/maa-remote-devhome`：`scripts` 软链到 `~/Developer/wados-maa/maa-remote/scripts`（也就是 `dev` 的工作区）。没有 `.env`：`run local` 照跑，只是不发 Discord（战报写进 `state/maa/runs/<场>-report.json`）。
- App 切环境：「设置 → 开发者 → 环境」，或 `defaults write io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome '~/.hermes'`；删掉这个 key 就回到开发副本。

## 部署 maa-remote

1. 在 `maa-remote/` 跑单测（同上）。
2. `git -C ~/Developer/wados-maa-deploy merge --ff-only dev`
3. 确认没有正在跑或快要开跑的场次：看 `~/.hermes/state/maa/run.lock`；早场 08:00、晚场 22:00，哪些 cron 开着以 `hermes cron list` 为准。
   然后 `cd ~/Developer/wados-maa-deploy/maa-remote && python3 deploy.py && python3 deploy.py --check`。
4. 动了 SKILL.md、adapter、`.env` 或 `config.yaml`，就要 `hermes gateway restart`。

## 上游 MaaMacGui

2026-11-09 起 GUI 退成纯 maa-remote 前端（`docs/REVIEW_2026-11-09.md` §1.4），**不再合并上游**：上游的 ViewModel、Core 绑定、任务配置、旧导航都已删掉，合并只会带回一堆冲突。
`gui/` 源自 MaaMacGui，仍按 AGPL-3.0 处理（上游仓库不带 LICENSE 文件，许可证在 MAA 主仓库；`maa-remote/LICENSE` 的 MIT 只管 `maa-remote/`）。历史里有上游的签名提交，不要对整个历史跑 filter-branch / filter-repo。

## Commit message

```
<type>: <中文一句话，写用户能看到的效果>

<正文，可省略：几行说清为什么改、怎么验证>
```

- `type` 只用 `feat` / `fix` / `refactor` / `test` / `docs` / `ci` / `chore`。冒号后空一格，标题末尾不加句号。
- 写得简洁。正文只在需要时写，几行就够；真机没验就直说。
- 一个 commit 只做一件事，顺手做的无关改动单独提交。
- **不许带** `Co-Authored-By`、会话 / thread 链接（`Claude-Session:`、`https://claude.ai/code/session_...` 等）、`Generated with Claude Code`。PR 描述同样不许带。

## 用户的工作方式

- 全程中文，时间一律说北京时间（cron 表达式是 UTC）。有多个问题时一次问完，每个都给推荐。
- 用户说「只规划」时只出文档，等放行再写代码。
- 硬约束：不吃理智药、不碎源石、不借助战；动游戏的流程必须持 `run.lock`。
- 不 push、不发 Discord 消息，除非用户明确要求。
