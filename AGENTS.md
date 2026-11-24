# Wado's MAA

明日方舟自动化。一个仓库，四个子目录：

| 目录 | 是什么 |
|---|---|
| `maa-remote/` | 后端：日常、抄作业、计划、活动监控等 Python 脚本，加常驻守护进程 `maa_daemon.py`（内置调度器 + HTTPS/SSE API）。部署到 `~/.wados-maa/` 才生效 |
| `gui/` | Mac App：纯 maa-remote 前端（SwiftUI），直接调本机脚本、读状态文件。起家于 MaaMacGui 的 fork，上游功能已全部删掉 |
| `ios/` | iPhone App（iOS 27，SwiftUI）：通过守护进程的 HTTPS API 连回 Mac mini，局域网直连，在外走 Cloudflare Tunnel |
| `shared/` | Swift 本地包 `WadosMAAShared`：`gui/` 和 `ios/` 共用的状态模型、北京时间、SPKI 等 |

2026-11-24 已完成生产切线：线上从 `~/.hermes`（Hermes cron + Discord）搬到 `~/.wados-maa`（自带守护进程 + Bark 推送 + iOS App）。`~/.hermes` 里的 MAA 脚本已换成拒绝桩，Hermes 只跑别的业务，**别再往 `~/.hermes` 部署 MAA**。

- 分支：平时在 `dev` 上提交；`main` = 线上已部署的版本。部署用的 worktree `~/Developer/wados-maa-deploy` 固定在 `main`。
- 远端：`origin` = `github.com/ffkiyo7/wadosMAA`；`upstream-gui` = 官方 MaaMacGui，只留作参考，**不再合并**。
- 旧仓库 `~/Developer/personal/maa-remote`、`~/Developer/forks/MaaMacGui` 只读备查。合仓时自有提交被改写过，旧文档里的提交号在新仓库查不到时去旧仓库查。

开工前先读：

- `maa-remote/docs/DEV_GUIDE.md`：后端链路，§8 是不变量，§12 是给 App 的本机接口，§13 是守护进程和 HTTP API。
- `docs/specs/README.md`：解耦与 iOS 的分阶段规格和当前进度（Phase 0～3 已完成，Phase 4 未开始）。
- `HANDOFF.md`：当前状态、待办和回滚办法。

## maa-remote

- 仓库不是运行目录。线上代码在 `~/.wados-maa/scripts/`，改完要部署才生效。排查线上问题以 `~/.wados-maa/` 里的代码、`state/maa/` 和 `logs/` 为准。
- 测试一律在 `maa-remote/` 里跑：`python3 -m unittest discover -s tests`。动了类型或 except，再跑 `uvx ruff@0.17.3 check` 和 `uvx pyright@1.1.414`。
- §8 的不变量不能破坏。
- 运行根目录按 `WADOS_MAA_HOME` → `HERMES_HOME` → `~/.wados-maa` 解析（`maa_common.resolve_home()`）。代码里仍叫 `HERMES_HOME` 的常量是同一个目录的旧名字。
- 守护进程跑 6 条内置任务（北京时间，不再有 UTC cron）：早晚计划卡、早晚日常、04:30 仓库对表（`depot_enabled`，默认关）、每 15 分钟活动监控。早晚场时间以 `config.json` 的 `session_schedule` 为准，查看用 `python3 ~/.wados-maa/scripts/maa_action.py schedule show`。
- 通知走 Bark（`maa_notify.py` + `barkcrypt` 加密）。Discord 代码还在，但线上没有 token，所有 Discord 出口都会跳过（#63）。
- `maa-remote/daemon/` 放一次性运维脚本：`init_daemon.py`（证书、Token、配对二维码）、`rotate_tls.py`（证书轮换）、`cutover.py`（切线与回滚），以及两个 LaunchAgent 模板。

## Mac App（gui/）

- 构建（输出不放仓库里）：

  ```bash
  xcodebuild -project gui/MeoAsstMac.xcodeproj -scheme MAA -configuration Release -derivedDataPath ~/Developer/forks/wados-maa-build/<名字> -skipMacroValidation -skipPackagePluginValidation build
  ```

- 纯前端：不链接 MaaCore、不持 `run.lock`；动游戏、动 maa-cli 的事都调 `maa_action.py`。启动时不自动更新，首页「游戏资源」卡片提示后由用户点「现在更新」。
- 源码在 `gui/MeoAsstMac/Remote/`（Xcode 同步文件夹，新增文件不用改 pbxproj），入口 `gui/MeoAsstMac/MeoAsstMacApp.swift`。
- 拒绝读写 `~/.hermes`（`RemoteConfig.disallowLegacyHermesHome`）：指到那里时什么都不做，提示改到 `~/.wados-maa`。
- 页面设计：避免不必要的辅助标签和文字描述，让界面布局自然地向用户传递信息。

## iOS App（ios/）

- 工程 `ios/WadosMAAiOS.xcodeproj`，scheme `WadosMAAiOS`，最低 iOS 27，自动签名（个人账号，描述文件 7 天过期，Phase 4 要做无线自动续签）。源码按 `App/`、`Core/`、`Design/`、`Shell/`、`Tabs/` 分，同样是同步文件夹。
- 构建和装到真机：

  ```bash
  xcodebuild -project ios/WadosMAAiOS.xcodeproj -scheme WadosMAAiOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath ~/Developer/forks/wados-maa-build/<名字> -allowProvisioningUpdates build
  ```

  ```bash
  xcrun devicectl device install app --device <UDID> ~/Developer/forks/wados-maa-build/<名字>/Build/Products/Release-iphoneos/WadosMAAiOS.app
  ```

- 只认 HTTPS API（DEV_GUIDE §13），不碰本机文件。配对靠守护进程生成的二维码（局域网地址、远程地址、SPKI 指纹、`full` Token），证书按 SPKI 固定，可存一个备用指纹。
- 界面按 iOS 原生重新设计，不照搬 Mac 版（设计稿 `docs/specs/P3_IOS_UI_DESIGN.md`）。

## shared/

- `gui/` 和 `ios/` 都以本地 Swift 包的方式引用 `shared/`。改模型时两个 App 都要能编过。
- 单测：`swift test --package-path shared`。

## 两个 App 怎么连到后端

- Mac App：子进程调 `$WADOS_MAA_HOME/scripts/maa_action.py`（argv、输出一行 JSON 回执），直接读 `state/maa/` 下的状态文件和 `run.lock`。接口见 DEV_GUIDE §12。
- iOS App：调守护进程的 `https://<局域网 IP>:18170/api/v1/*`，或 `https://maa.luxraykit.com`（Cloudflare Tunnel）。接口见 DEV_GUIDE §13。
- 改接口时后端和 App 在同一个提交里改、一起验证。
- 运行根目录有两个：
  - 线上 `~/.wados-maa`：守护进程、真实调度、真实游戏、Bark。
  - 开发副本 `~/Developer/forks/maa-remote-devhome`：`scripts` 软链到 `~/Developer/wados-maa/maa-remote/scripts`（即 `dev` 工作区），有自己的 `daemon/`。它的 `daemon.json` 和线上一样用 18170 端口，所以**线上守护进程在跑时不能再起开发副本的守护进程**；要用 iOS 测开发副本，得先和用户约好时间停线上服务。
- Mac App 切环境：「设置 → 开发者 → 环境」，或 `defaults write io.github.ffkiyo7.MaaRemoteGui RemoteHermesHome '~/.wados-maa'`；删掉这个 key 就回到开发副本。现在指向线上。

## 部署 maa-remote

1. 在 `maa-remote/` 跑单测和静态检查（同上）。
2. `git -C ~/Developer/wados-maa-deploy merge --ff-only dev`
3. 确认没有正在跑或 30 分钟内要开跑的场次：看 `~/.wados-maa/state/maa/run.lock` 和 `schedule show`。
4. 部署并体检。**必须带 `--standalone`**：不带时 `deploy.py` 走旧的 Hermes 模式，会往 `~/.hermes` 写。

   ```bash
   cd ~/Developer/wados-maa-deploy/maa-remote && python3 deploy.py --standalone && python3 deploy.py --standalone --check
   ```

5. 重启守护进程，让常驻进程加载新代码（它 import 了 `maa_action` / `maa_common` 等大部分模块；定时任务每次都起新进程，不受影响）。重启不会杀掉正在跑的场次：

   ```bash
   launchctl kickstart -k gui/$(id -u)/io.github.ffkiyo7.wados-maa.daemon
   ```

6. 动了 iOS 或 Mac App，就按上面的命令从 `~/Developer/wados-maa-deploy` 重新构建安装。

线上 LaunchAgent：`io.github.ffkiyo7.wados-maa.daemon`（守护进程，经 `wados-maa-launcher` 启动，辅助功能权限授给这个 launcher）和 `io.github.ffkiyo7.wados-maa.cloudflared`（隧道）。日志在 `~/.wados-maa/logs/`。

## 上游 MaaMacGui

2026-11-09 起 GUI 退成纯 maa-remote 前端（`docs/REVIEW_2026-11-09.md` §1.4），**不再合并上游**。
`gui/` 源自 MaaMacGui，仍按 AGPL-3.0 处理；`ios/`、`shared/` 各带 LICENSE；`maa-remote/LICENSE` 的 MIT 只管 `maa-remote/`。历史里有上游的签名提交，不要对整个历史跑 filter-branch / filter-repo。

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

- 全程中文，时间一律说北京时间。有多个问题时一次问完，每个都给推荐。
- 用户说「只规划」时只出文档，等放行再写代码。
- 硬约束：不吃理智药、不碎源石、不借助战；动游戏的流程必须持 `run.lock`。
- 不 push、不发 Bark / Discord 消息，除非用户明确要求。
