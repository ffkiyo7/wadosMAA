# S0b spike：更新源对照、版本信号与冲突处理

> 2026-11-06 12:15（北京时间）。**只读调研**：只读了文件，跑过 `maa version`、`maa --help` 和各子命令的 `--help`、`brew info`、`git -C <MaaResource> log -1`、`python3 deploy.py --check`。没有跑任何 update / install / run。
> 现场：maa-remote `fbf3f19`（线上 `~/.hermes/scripts/` 与仓库一致，`deploy.py --check` 的 `mismatched` 为空）；MaaMacGui `b2c99a8`。
> 本文只出方案，不含实现。

## 0. 结论

1. **只认 maa-cli 这一个更新源是可行的，而且该这么做。** 两边的上游其实是同一批东西（MaaCore 的 GitHub release、MaaResource 仓库、api.maa.plus 的 OTA 文件），只是下载方式、落盘位置、版本判定各搞一套。GUI 自己的四条联网更新路径（Sparkle、资源 GitHub/Mirror 酱、OTA、启动时查新版本）全部关掉，改成读 maa-cli 的目录。
2. **Sparkle 必须删，不只是关**：fork 保留着上游的 `SUFeedURL` 和 `SUPublicEDKey`，上游发的更新包能通过 EdDSA 校验，可能把 fork 整个换成官方 MAA.app（§3.2）。
3. **去沙盒之前必须先拆掉 `loadResource(channel:)` 里的删目录逻辑**：Debug 构建每次启动都会 `rm -rf <Documents>/resource`。去沙盒后 `<Documents>` 变成 `~/Documents`（§3.3）。这是 S1 的 P0。
4. **07:50 的更新链有个现成 bug：从北京时间 10-18 起，早场卡天天报「上游更新失败」，maa-cli 一直没升级。** `brew outdated <formula>` 在有新版时退出码是 1，`upgrade_maa_cli()` 把它当成失败，直接返回，`brew upgrade` 一次都没跑过。现状：装的是 0.7.5，可用 0.7.8。MaaCore 和资源不受影响，那两步不依赖这一步（§2.5）。
5. **GUI 要触发更新，必须调 maa-remote 的同一个函数，不能在 Swift 里重写一遍。** 推荐把 `check_and_update_upstream()` 拆成独立模块，再给 `maa_action.py` 加 `upstream status` 和 `upstream update` 两个命令，07:50 卡和 GUI 共用（§6(d)）。更新期间持有 `run.lock`。
6. **不一致的处理推荐「分级」**（§6(c) 选项 B）：本地状态不自洽时拒跑，比如 Core 换了但资源没跟上，或者 GUI 进程里的 Core 已经不是盘上那份；只是联网检查或更新失败、本地自洽时，按现有版本继续，同时在界面和战报上标出来。如果一律拒跑，按第 4 条那个 bug，从 10-18 到今天每场都会被挡下。
7. **GUI 从 Finder 启动时拿不到代理环境变量，PATH 里也没有 brew。** 现在 cron 的代理来自 gateway 的 launchd plist（`HTTP(S)_PROXY=http://127.0.0.1:7890`），系统代理是关的。GUI 起 maa-remote 子进程时要显式补上这两样，否则 `brew` 会被静默跳过，`maa update` 会直连 GitHub（§6(d)）。

---

## 1. 现场快照（12:15）

| 项 | 值 | 读法 |
|---|---|---|
| maa-cli | v0.7.5（brew 显示可用 0.7.8） | `maa version`；`brew info MaaAssistantArknights/tap/maa-cli` |
| MaaCore | v6.21.4（11-05 07:50 装上） | `maa version`；`asst.log` 里 `MaaCore Process Start` 下一行 `Version v6.21.4` |
| Beta 通道最新 Core（缓存） | v6.21.4，`prerelease: false` | `~/Library/Caches/com.loong.maa/core-manifest-beta.json` 的 `.version`，11-06 07:50 刷新 |
| 基础资源 `last_updated` | `2026-11-03 12:56:51.000` | `~/Library/Application Support/com.loong.maa/resource/version.json` |
| MaaResource `last_updated` | `2026-11-04 18:33:23.000` | `…/com.loong.maa/MaaResource/resource/version.json` |
| MaaResource HEAD | `99ad799f`，2026-11-05 15:07 UTC，等于 `origin/main` | `git -C …/MaaResource log -1` |
| `verified_versions.json` 漂移 | MaaCore v6.21.3 → v6.21.4，只进 warnings | `deploy.py --check` 的 `versions` |
| 上次更新 | 11-06 07:50，`resource_update_status: failed`（就是 §2.5 的 brew bug），HEAD 从 `42ed1693` 快进到 `99ad799f` | `~/.hermes/state/maa/last_run.json` |
| 早场卡 cron 结果 | 北京时间 10-18 07:50 起每天（cron 输出文件名是 UTC，10-17_23-50） `exited with code 1`：「maa 上游更新失败」；之前都是 ok | `~/.hermes/cron/output/03d5e98ce8d4/*.md` |
| cron | 11:49 起暂停（PLAN_MACGUI 记录），07:50 这趟已经跑完 | — |

注意：两个 `last_updated` 只反映国服。11-05 那个 commit 只改了 YoStar 三服的 `version.json`，HEAD 变了，国服的 `last_updated` 没变。**判断 MaaResource 有没有更新要看 git HEAD，不能只看 `last_updated`。**

---

## 2. maa-cli 这边

### 2.1 文件与目录

| 东西 | 路径 | 读法 | 谁写 / 哪条命令更新 | 联网对代理 |
|---|---|---|---|---|
| maa-cli 本体 | `/opt/homebrew/Cellar/maa-cli/<ver>/bin/maa` ← `/opt/homebrew/bin/maa` | `maa version maa-cli`；`brew info --json=v2 …` 的 `installed[].version` / `versions.stable` | `brew upgrade --formula MaaAssistantArknights/tap/maa-cli`。这个 brew 构建**没有** `maa self` 子命令，只能靠 brew 升级 | **要代理**（brew 的 tap 走 git，bottle 从 ghcr 下载） |
| MaaCore 动态库 | `~/Library/Application Support/com.loong.maa/lib/libMaaCore.dylib` 等 7 个 | `maa version maa-core`，会加载 dylib 并调 `AsstGetVersion` | `maa update --batch`。通道由 `cli.toml` 的 `[core] channel = "Beta"` 决定 | **要代理**（release zip 在 GitHub 上；2026-08-16 剥掉代理后超时过一次） |
| 基础资源 | `…/com.loong.maa/resource/` | `version.json` 的 `last_updated` / `activity` / `gacha` | 跟 Core zip 一起由 `maa update` 解压 | 同上 |
| Core 版本清单缓存 | `~/Library/Caches/com.loong.maa/core-manifest-beta.json`（+`.etag`）、`core-manifest-stable.json` | `.version`、`.details.tag_name` / `prerelease` | `maa update` 拉 `https://api.maa.plus/MaaAssistantArknights/api/version/…`，按 ETag 缓存 | 同上 |
| Core 安装包缓存 | `~/Library/Caches/com.loong.maa/MAA-v*-macos-runtime-universal.zip` | — | `maa update` 下载，**从来不清**，现在 9 个约 1.9 GB | — |
| MaaResource 热更新层 | `…/com.loong.maa/MaaResource/`（git 仓库，remote 是 `github.com/MaaAssistantArknights/MaaResource.git`，分支 `main`） | `git -C … rev-parse HEAD`；`resource/version.json` | `maa hot-update --batch`；`cli.toml` 里 `backend = "git"`，`auto_update = false` | **要代理**，而且只有 `git` 后端认环境变量里的代理（DEV_GUIDE §11.18） |
| OTA tasks | `~/Library/Caches/com.loong.maa/resource/tasks/tasks.json`，`…/resource/platform_diff/iOS/resource/tasks/tasks.json`，`…/resource/global/<服>/resource/tasks/tasks.json`，各带一个 `.etag` 文件 | 文件 mtime 和 `.etag`；没有版本号 | maa-cli 的 `hot_update` 模块：每次 `maa run` 开头都会打「Updating hot update files…」，从 `https://api.maa.plus/MaaAssistantArknights/api/resource/…` 按 ETag 拉 | **不能带代理**：日常 `maa run` 剔除代理，否则 in-run hot update 报错（不变量 #12、§11.9） |
| 活动日历 | `~/Library/Caches/com.loong.maa/StageActivityV2.json`（+`.etag`） | `Official.sideStoryStage.<前缀>.{Activity, Stages, MinimumRequired}`；时间字段的读法见 DEV_GUIDE §3 | `maa activity Official`（计划卡每场一次、activity watcher 每 15 分钟一次），`maa run` 也会刷新 `.etag` | 不带代理，现在一直这么跑 |
| 用户资源层 | `~/.config/maa-cli/resource/tasks/tasks.json`、`template/UiTheme/Sanrio/*.png` | 和仓库 `config/maa-cli/resource/**` 逐字节比对 | 只由 `deploy.py` 写，仓库管理 | 不联网 |
| 钉住更新源的配置 | `~/.config/maa-cli/cli.toml` | `[core] channel`；`[resource] auto_update / backend` | 只由 `deploy.py` 写；`--check` 逐字节守着 | — |
| maa-remote 运行时缓存 | `~/.hermes/state/maa/config.json` 的 `maa_cli_version` / `maa_core_version` | JSON | 07:50 卡在更新后写回（`persist_installed_versions()`）；不变量 #25 保护它们不被部署覆盖 | — |
| 更新结果 | `~/.hermes/state/maa/last_run.json` 的 `resource_update_{attempted_at,status,detail,summary,changed}`，以及 `maa_cli_version`、`maa_core_version` | JSON | 07:50 卡写 | — |
| 实际跑的 Core | `…/com.loong.maa/debug/asst.log`，每次进程启动都打 `Version vX` | grep | MaaCore 自己写 | — |

**`maa_core_version` 有下游消费者**：`maa_copilot.core_too_old()` 拿它和作业的 `minimum_required` 比。GUI 自己更新 Core 却不写这个键，抄作业的版本闸门就会用旧值。这是 §6(d) 必须复用同一个函数的又一个理由。

### 2.2 资源加载顺序（`asst.log` 实证，11-06 08:00 那场）

maa-cli 给 MaaCore 依次 `AsstLoadResource` 了 6 层，后加载的覆盖先加载的：

1. `com.loong.maa/resource`：基础资源，跟 Core 一起装；
2. `com.loong.maa/MaaResource/resource`：git 热更新层；
3. `~/Library/Caches/com.loong.maa/resource`：OTA tasks；
4. `~/.config/maa-cli/resource`：用户层，不变量 #4、#59 的修复在这一层；
5. `com.loong.maa/resource/platform_diff/iOS/resource`；
6. `~/Library/Caches/com.loong.maa/resource/platform_diff/iOS/resource`。

上游 GUI 的顺序不一样：每加载一层，紧跟着加载**这一层自己的** `platform_diff/iOS`；也不拉 iOS 的 OTA。fork 改读 maa-cli 的目录时，要**照这 6 层原样复刻**，否则 GUI 和 cron 跑的不是同一套资源，「一致」也就无从谈起。复刻的实现归 S0a / S1 管。

### 2.3 07:50 早场卡的更新链（`scripts/maa_plan_card.py`）

`main()` 只在 `phase == "am"` 时调 `check_and_update_upstream()`（不变量 #40），顺序如下：

1. `read_maa_versions()`：跑 `maa version`，带代理，解析靠 `parse_maa_versions()`；
2. `upgrade_maa_cli()`：先 `brew outdated --quiet --formula <formula>`（允许 brew 自动 update），再 `brew upgrade --formula`（`HOMEBREW_NO_AUTO_UPDATE=1`），超时 `maa_cli_update_timeout`，默认 180s；
3. `update_maa_core()`：`maa update --batch`，带代理，超时 `resource_update_timeout`，默认 300s；
4. `update_hot_resources()`：`maa hot-update --batch`，带代理，300s。**只有第 3 步成功才跑**（DEV_GUIDE §11.16：Core 和 MaaResource 必须一起前进）；
5. 再读一次版本，`persist_installed_versions()` 写回 `config.json`，`merge_last_run()` 写 `resource_update_*`；
6. 失败就发红色 Embed，`main()` 末尾 `raise`，cron 记为失败。

另外，每场计划卡都跑 `refresh_activity_stages()`：`maa activity Official`，不带代理。activity watcher 每 15 分钟也跑同一条。

**这条链没有拿 `run.lock`。** 现在靠时间错开：07:50 离 08:00 还有 10 分钟，手动场、抄作业、肉鸽都有 blackout，进不来。最坏情况三步加起来要 13 分钟，会和 08:00 的日常重叠。GUI 要是能随时触发更新，或者能在 blackout 内强行开跑（PLAN S3），就必须加锁（§6(c)）。

代理规则（不变量 #11、#12）：所有 maa-cli 子进程都由 `maa_subprocess_env()` 注入 `MAA_CONFIG_DIR`。`maa_disable_proxy=true` 时，运行类子进程（run / activity / copilot / depot / roguelike）剔除 `*_PROXY`；`maa version` / `update` / `hot-update` 传 `keep_proxy=True`，保留代理；brew 的环境整份拷贝自父进程。**代理的来源是 `~/Library/LaunchAgents/ai.hermes.gateway.plist` 的 `EnvironmentVariables`**（`HTTP_PROXY` / `HTTPS_PROXY` 及小写版本，都是 `http://127.0.0.1:7890`）。系统代理（`scutil --proxy`）三项都是 0。

### 2.4 刷新频率小结

| 东西 | 刷新时机 | 现在（cron 暂停） |
|---|---|---|
| maa-cli | 07:50 早场卡；10-18 起被 §2.5 卡住，实际没升级过 | 停 |
| MaaCore + 基础资源 | 07:50 早场卡 | 停 |
| MaaResource | 07:50 早场卡，Core 那步成功之后 | 停 |
| OTA tasks | 每次 `maa run`，也就是每场日常、Depot、肉鸽、抄作业 | Discord 手动入口还能触发 |
| StageActivityV2 | 每张计划卡、activity watcher 每 15 分钟、`maa run` | 同上 |

### 2.5 发现：`upgrade_maa_cli()` 把「有新版」当成失败

- Homebrew 的 `cmd/outdated.rb` 第 96 行是 `Homebrew.failed = args.named.present? && outdated.present?`：**点名查一个 formula，它有新版时退出码就是 1**。
- `upgrade_maa_cli()` 遇到 `code != 0` 就返回 `ok: False`，`brew upgrade` 根本走不到。
- 后果：
  - 北京时间 10-18 起早场卡天天红，maa-cli 停在 0.7.5，现在可用 0.7.8；
  - `verified_versions.json` 里那个「验证过的 v0.7.5」，其实是升不上去的结果；
  - Core 和资源照常更新，因为它们不依赖 `cli_step`，所以没人发现；
  - 红卡天天亮，已经没人看了。
- 单测没拦住：`tests/test_plan_card.py` 的桩把「有新版」写成了 `returncode=0` 加非空 stdout，和 brew 的真实行为不符。
- 修法（以后在分支上做）：
  - `code == 1` 且 stdout 里有这个 formula，就当「有新版」处理；
  - 或者改用 `brew outdated --json=v2 <formula>`，只按解析结果判断，不看退出码。
- 一修好，下一次更新就会把 maa-cli 从 0.7.5 跳到 0.7.8。DEV_GUIDE 里有好几条不变量是按 0.7.5 的行为写的（`[[tasks]]` 数组、肉鸽 CLI 的限制等）。**升级后要真机跑一场**，再按 §7.1 更新 `verified_versions.json`。

---

## 3. 上游 GUI 这边（MaaMacGui `b2c99a8`）

### 3.1 联网更新路径

下表的 `<Docs>` 指 `FileManager.urls(for: .documentDirectory)`：

- 沙盒里是 `~/Library/Containers/<bundle id>/Data/Documents`；
- **去沙盒后是 `~/Documents`**。

| # | 路径 | 触发 | 网络端点 | 写哪里 | 版本怎么判 | 默认开没开 |
|---|---|---|---|---|---|---|
| G1 | **Sparkle，整个 App 更新** | `MeoAsstMacApp.init` 建 `SPUStandardUpdaterController(startingUpdater: isRelease)`；菜单「检查更新…」；设置页「自动检查 / 自动下载 / 接收开发版更新」 | `SUFeedURL = https://maa-release.hguandl.com/macos/appcast.xml`；`MaaUseBetaChannel` 为真时允许 `beta` 频道 | 整个 `.app` 被替换，**包括里面的 `MaaCore.framework` 和 `Contents/Resources/resource`**；Sparkle 自己的缓存和 `SU*` 偏好 | appcast 的版本号，加 EdDSA 签名（`SUPublicEDKey`） | **Release 启动 updater**。Info.plist 没写 `SUEnableAutomaticChecks`，Sparkle 会在第二次启动时问用户要不要自动检查；菜单随时能手动查。Debug 不启动 updater，菜单是灰的 |
| G2 | **启动时查资源新版本**（`loadResource(channel:)` 末尾那个 `Task`） | 每次 `loadResource(channel:)`：启动、切客户端、切触控模式 | GitHub：`github.com/MaaAssistantArknights/MaaResource/raw/refs/heads/main/resource/version.json`；Mirror 酱：`mirrorchyan.com/api/resources/MaaResource/latest?current_version=…&cdk=…` | 只写日志。`AutoResourceUpdate` 为真时把 `showResourceUpdate` 置真，弹出 G3 | 远端 `last_updated` / `version_name` 和本地 `last_updated` **做字符串比较** | **Release 每次都查**，默认走 GitHub。Debug 跳过（`#if DEBUG guard false`） |
| G3 | **资源包更新**（`ResourceUpdateView`） | 侧栏按钮手动点；或 G2 发现新版且 `AutoResourceUpdate == true`，弹窗出来就自动开始 | GitHub：`github.com/…/MaaResource/archive/refs/heads/main.zip`；Mirror 酱：接口返回的 `url`，要 CDK | `$TMPDIR/MaaResource.zip` → 解压到 `$TMPDIR/MaaResource-main` 或 `$TMPDIR/resource` → 用 `replaceItemAt` **逐个文件合并覆盖**进 `<Docs>/resource/`（不删旧文件）→ `reloadResources()` | 同 G2；`latestURL()` 要求远端比本地新，否则抛 `noNeedUpdate` | `AutoResourceUpdate` 默认 **false**，`ResourceUpdateChannel` 默认 **github**。改了 bundle id（K8）就是一套新的 UserDefaults，取默认值 |
| G4 | **OTA**（`fetchOTAResource`） | 每次 `loadResource(channel:)`，**没有开关** | `https://api.maa.plus/MaaAssistantArknights/api/` 下的 `resource/tasks.json`、`gui/StageActivityV2.json`，外服再加 `resource/global/<服>/resource/tasks.json`。**不拉 `platform_diff/iOS`** | `<Docs>/cache/resource/tasks/tasks.json`、`<Docs>/cache/gui/StageActivityV2.json`、`<Docs>/cache/resource/global/…`；ETag 存在 UserDefaults 的 `OTAETags` 字典里 | HTTP ETag，304 就跳过 | **Debug 和 Release 都开** |
| G5 | 作业下载（prts.maa.plus） | — | — | — | — | 按要求不管 |

和资源相关的本地行为：

- `MAAResourceChannel.version()`：`<Docs>/resource/version.json` 比 App 自带的新，就优先用 `<Docs>`；Debug 永远返回 App 自带的那份；
- 加载顺序：App 自带 → `<Docs>`（如果更新）→ `<Docs>/cache`，MacPlayTools 模式下每层后面跟它自己的 `platform_diff/iOS`；
- `MAAViewModel.userDirectory` 是 `applicationSupportDirectory`，用来 `AsstSetUserDir`；去沙盒后会变成 `~/Library/Application Support` 的**根目录**。

### 3.2 Sparkle 为什么要删，而不是关

- fork 的 Info.plist 还留着上游的 feed URL 和 EdDSA 公钥。上游发的包用的就是这把私钥签的，**能过 EdDSA 校验**。
- Sparkle 2 允许代码签名身份变化，前提是 EdDSA 校验通过。按这个规则，fork 改用 `Apple Development` 证书签名之后，上游更新包仍然会被接受，fork 被换成官方 MAA.app，Core 和资源也一起换成上游自带的那份。这一条是按规则推出来的，没有实测。
- K8 本来就要删 Sparkle。这里补一个硬理由：只关「自动检查」不够，菜单里的「检查更新…」和 `SPUUpdater` 的定时检查还在。

### 3.3 去沙盒前必须先拆的东西（S1 的 P0）

1. `loadResource(channel:)` 里，`preferUser == false` 时会执行 `try? FileManager.default.removeItem(at: <Docs>/resource)`。
   - Debug 构建的 `version()` 永远返回 `preferUser = false`，所以**每次启动都会删**；
   - 去沙盒后删的就是 **`~/Documents/resource`**。
2. G3 和 G4 往 `<Docs>` 下写 `resource/` 和 `cache/`。去沙盒后会写进 `~/Documents`，如果开了「桌面与文稿」iCloud 同步，还会被同步上去。
3. `AsstSetUserDir(~/Library/Application Support)`：去沙盒后 MaaCore 会把 `debug/`、`cache/` 等写进 Application Support 根目录。user dir 放哪里，由 S0a 决定。

**这三条要在去沙盒的同一个 commit 里改掉，或者放在它前面。**

---

## 4. 两边更新路径对照

| 东西 | maa-remote（maa-cli） | 上游 GUI | 冲突点 | 取舍 |
|---|---|---|---|---|
| App / 启动器 | maa-cli 走 brew，07:50 跟新（§2.5 的 bug 修了才真跟得上） | Sparkle 换整个 App | Sparkle 会覆盖 fork | 删 Sparkle。fork 靠 `git fetch upstream` + 重新编译，手动跟 |
| MaaCore | `maa update`，**Beta 通道**（api.maa.plus 版本清单 → GitHub release zip） | 打包在 App 里，只能跟 Sparkle 一起换。Sparkle 默认是 stable，勾了「开发版」才是 beta | 版本可能不同，两套库共存 | **maa-cli Beta**。GUI 直接用 maa-cli 那份（S0a） |
| 基础资源 | 跟 Core zip 走，在 `com.loong.maa/resource` | App 自带的 `Contents/Resources/resource` | 同上 | maa-cli |
| 热更新资源 | MaaResource **git**（`hot-update`，`backend = git`，要代理） | GitHub `main.zip` 或 Mirror 酱 → `<Docs>/resource`，按文件合并覆盖 | 同一个上游仓库，两种传法、两个落点、两个版本 | maa-cli git |
| OTA tasks | `maa run` 自动拉到 `~/Library/Caches/com.loong.maa/resource/**`，**含 iOS**，不带代理 | 每次加载资源都拉到 `<Docs>/cache`，**不含 iOS**；ETag 存在 UserDefaults | 两份缓存，GUI 少了 iOS 那层 | maa-cli。GUI 不再联网，只按 §2.2 读这几层 |
| StageActivityV2 | `maa activity` / `maa run` 拉到 `~/Library/Caches/com.loong.maa/StageActivityV2.json` | `<Docs>/cache/gui/StageActivityV2.json` | 同一个 URL，两份副本 | maa-cli 那份。GUI 只读，`[String: MAAStageActivity]` 的解码结构不用改 |
| 用户资源层 | `~/.config/maa-cli/resource`，仓库管理 | 没有 | GUI 里不变量 #4、#59 不生效 | GUI 照 §2.2 第 4 层加载（S1） |
| 什么时候查 | 07:50 一次，晚场不查（#40） | 每次加载资源 | — | 见 §6(b) |

---

## 5. 版本信号清单

「离线」指不联网、不改任何东西、1 秒级就能读完。

| # | 信号 | 路径 / 命令 | 读法 | 离线？ |
|---|---|---|---|---|
| V1 | maa-cli 装的版本 | `MAA_CONFIG_DIR=~/.config/maa-cli maa version maa-cli` | `maa-cli vX.Y.Z`，复用 `parse_maa_versions()` | 是 |
| V2 | maa-cli 可用版本 | `HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 MaaAssistantArknights/tap/maa-cli` | `formulae[0].versions.stable`。数据来自本地 tap 快照，只有 `brew update` 之后才是新的 | 是（数据可能旧） |
| V3 | 盘上 MaaCore 版本 | `maa version maa-core` | `MaaCore vX.Y.Z` | 是 |
| V4 | GUI 进程里加载的 Core 版本 | GUI 调 `AsstGetVersion()`。现在 fork 里**没有调用**，要在 S3 加 | 字符串 | 是 |
| V5 | Beta 通道最新 Core（上次查到的） | `~/Library/Caches/com.loong.maa/core-manifest-beta.json` | `.version`；文件 mtime 就是上次查的时间 | 是（数据可能旧） |
| V5' | Beta 通道最新 Core（实时） | 同一个 api.maa.plus 版本清单，确切 URL 见 §7 | `.version` | 否，要代理 |
| V6 | 基础资源 | `…/com.loong.maa/resource/version.json` | `last_updated`，格式 `YYYY-MM-DD HH:MM:SS.mmm`，可以按字典序比 | 是 |
| V7 | MaaResource 本地 | `git -C …/MaaResource rev-parse HEAD`；`resource/version.json` 的 `last_updated` | **以 HEAD 为准**（见 §1 的注意） | 是 |
| V7' | MaaResource 远端 | `git ls-remote https://github.com/MaaAssistantArknights/MaaResource.git refs/heads/main` | 远端 HEAD | 否，要代理 |
| V8 | OTA tasks | `~/Library/Caches/com.loong.maa/resource/**/tasks.json` 和 `.etag` | mtime 和 ETag；只拿来算「资源签名」，不当版本号用 | 是 |
| V9 | 活动日历 | `~/Library/Caches/com.loong.maa/StageActivityV2.json` | mtime；各活动的 `MinimumRequired` 要 ≤ V3 | 是 |
| V10 | 钉住的源没被改 | `~/.config/maa-cli/cli.toml` | `core.channel == "Beta"`、`resource.backend == "git"`、`resource.auto_update == false`；`deploy.py --check` 也会逐字节查 | 是 |
| V11 | 用户资源层没漂 | `~/.config/maa-cli/resource/**` | `deploy.py --check` 的 `mismatched` 为空；GUI 侧可以只算 `tasks.json` 的 sha256 | 是 |
| V12 | 上次更新结果 | `~/.hermes/state/maa/last_run.json` 的 `resource_update_attempted_at` / `status` / `detail` / `changed` | 时间和 ok / failed。**现在没有分步结果**，§6(d) 要补 | 是 |
| V13 | maa-remote 缓存的版本 | `~/.hermes/state/maa/config.json` 的 `maa_core_version` / `maa_cli_version` | 应该等于 V3 / V1；不等就说明有人绕开 maa-remote 更新过 | 是 |
| V14 | 实际跑过的 Core | `…/com.loong.maa/debug/asst.log` 里 `MaaCore Process Start` 下一行 | `Version vX`，事后排查用 | 是 |
| V15 | 真机验证记录 | 仓库 `config/verified_versions.json`；`deploy.py --check` 的 `versions` | 只做漂移提示，不进判定（§7.1 的原意） | 是 |
| V16 | 有没有人正在跑 | `~/.hermes/state/maa/run.lock`（`flock` 非阻塞试一下，即 `is_run_locked()`） | 被占 = 有一场在跑，或正在更新 | 是 |

「资源签名」= V6 + V7 HEAD + V8 各文件的 ETag + V11 的 sha256。GUI 加载资源时记一份，开跑前再算一份，两份对比。maa-remote 的 `maa_copilot.resource_signature()` 已经有类似的东西（V6 / V7 的 `last_updated` 加 Tile-Pos 目录的 mtime），可以扩展它。

---

## 6. 方案

### (a) 上游哪些路径关掉、哪些改道

| 路径 | 处理 | 改到哪 |
|---|---|---|
| G1 Sparkle | **删**：SPM 依赖、Info.plist 里的 `SU*` 键、`CheckForUpdatesView`、`UpdaterSettingsView` 的前三项、`MaaUpdaterDelegate`、`MaaUseBetaChannel` | fork 自己的更新：手动 `git fetch upstream`，合并后重新编译 |
| G2 启动查资源版本 | **删** | §6(b) 的状态检查，数据来自 `maa_action.py upstream status` |
| G3 资源包更新 | **删**：`ResourceUpdateView`、`MAAResourceChannel`、`GitHub.swift`、`MirrorChyan.swift`、Mirror 酱 CDK 的钥匙串读写（K8 去掉 entitlement 后，Release 那个 access group 本来也用不了）、`AutoResourceUpdate` / `ResourceUpdateChannel` | 侧栏「更新」按钮改成调 `upstream update`，设置页显示 §5 的信号 |
| G3 附带的删目录逻辑 | **删**（§3.3，P0） | — |
| G4 OTA | **不再联网** | 读 maa-cli 的缓存：§2.2 的第 3、6 层，以及 `~/Library/Caches/com.loong.maa/StageActivityV2.json`（目前只有 `MiniGameView` 用；`DailyStageTipView` 传的是 `nil`）。这些文件由 maa-cli 刷新。GUI 想在启动时刷一下活动日历，可以起一个子进程跑 `maa activity Official`，**不带代理**，约 1 秒。这条命令会不会顺便刷 OTA tasks 还没确认（§7） |
| App 自带的 Core / 资源 | **不再使用**（S0a） | maa-cli 的 `lib/`，以及 §2.2 的 6 层 |

S0a 的结论会影响这里。如果 fork 只能打包自带 Core、链不上 maa-cli 那份：

- GUI 只能读 maa-cli 的资源目录，然后在编译期把 Core 钉成和 maa-cli 同一个版本；
- 一旦 V3 ≠ V4（盘上和进程里的 Core 不一样），GUI 里的上游手动功能整体禁用；
- 「我们的流程」走 maa-remote 子进程（K4），不受影响。

这是降级方案，不推荐。

### (b) 启动时和开跑前比对什么，怎样算「一致」

把检查结果分成五种：

| 判定 | 条件 | 怎么算 |
|---|---|---|
| **钉住** | V10 全满足，V11 没漂 | 不满足 = **源被改了**，属于硬不一致 |
| **自洽** | 最近一次更新**没有**出现「Core 变了、MaaResource 这一轮却失败」 | 需要 V12 补分步字段（`core_changed`、`hot_ok`），见 (d)。旧数据没有这些字段时按「自洽」处理，并提示一句 |
| **新鲜** | 最近一次**成功**的更新距今 ≤ 24 小时 | 正常情况下 07:50 那趟就够；cron 停了的时候靠 GUI 补上 |
| **GUI 同步** | V4 == V3，且「资源签名」等于 GUI 上次加载时记下的那份 | 只对 GUI 进程里的 Core 有意义（上游手动功能）。走 maa-remote 子进程的我们自己的流程，不看这一条 |
| **上游有新版** | V5' > V3，或 V7' ≠ V7，或 V2 > V1 | 只在 GUI 启动和手动点「检查更新」时查，开跑前不查（要联网，慢） |

什么时候查哪几项：

- **GUI 启动**（在 `initialize()` 加载 Core **之前**）：
  - 先查「钉住 / 自洽 / 新鲜」，离线，< 2 秒；
  - 不新鲜、闸门（见 (c)）也放行，就先更新，**更新完再加载 Core**。这样不会出现盘上的 dylib 在已加载的进程底下被换掉的情况；
  - 「上游有新版」放到后台查，结果只显示，不自动动手。
- **每次开跑前**，GUI 手动场和 cron 的定时场都算：
  - 查「钉住 / 自洽 / 新鲜」，离线；
  - GUI 进程内的上游功能再加查「GUI 同步」。

满足全部离线条件就算「一致」，具体是：钉住、自洽、新鲜，进程内功能再加 GUI 同步。

`verified_versions.json` 的漂移（V15）**不算**不一致，只显示。

### (c) 不一致时怎么处理

先说两条无论选哪个方案都成立的硬规则：

- **更新期间必须持有 `run.lock`**（非阻塞地抢）。抢不到就不更新，结果记为「跳过：另一场在跑」。这样「`run.lock` 被占着时不能更新」和「更新时不能开跑」都由同一把锁保证。
- **开发期（K1，`HERMES_HOME=<devhome>`）GUI 只检查、不更新。** maa-cli 的目录是整台机器共用的，devhome 的那把 `run.lock` 却不是线上那把。Discord 的手动入口还开着，GUI 在 devhome 里更新，挡不住线上那边。开发期要更新，就在终端里以线上 `HERMES_HOME` 手动跑。

三个选项：

| | **A. 一律拒跑**（fail-closed） | **B. 分级**（推荐） | **C. 只检查、由人决定** |
|---|---|---|---|
| 源被改了（V10 / V11 不满足） | 拒跑 | **拒跑**，提示跑 `deploy.py` | 拒跑 |
| 不自洽：Core 换了、MaaResource 没跟上 | 拒跑 | **拒跑**，先自动重试一次 `hot-update`，还不行再拒跑 | 弹窗让人选 |
| GUI 进程内 Core ≠ 盘上（V4 ≠ V3） | 拒跑 | 只挡进程内的上游功能，提示「重启 App 以加载新 Core」；我们的流程照跑 | 弹窗 |
| 正在更新（锁被更新进程占着） | 拒跑 | 等它跑完，有上限，超时就按「锁被占」处理 | 弹窗 |
| 不新鲜（> 24 小时） | 先更新，失败就拒跑 | 先更新（闸门放行时）；失败就**降级继续** | 弹窗：「现在更新 / 跳过本次 / 取消」 |
| 联网检查或更新失败，本地自洽 | 拒跑 | **降级继续**，GUI 黄条，战报加一行「上游检查失败：<原因>；按 Core vX / 资源 <HEAD 短号> 继续」；连续 3 天失败升为红色提醒，但仍不拒跑 | 弹窗 |
| maa-cli（brew）那步失败 | 拒跑 | **从不挡跑**，只报告 | 只报告 |
| 优点 | 绝不在混合状态上跑 | 只在真不安全时挡；网络抖动、GitHub 抽风不会让日常停摆 | 实现最简单 |
| 缺点 | 按 §2.5，10-18 到今天每场都会被挡；网络一抖就停 | 规则多，要补分步记录 | 定时场没人点弹窗，「保持自动更新」只能靠 07:50 卡；GUI 不开就没人补 |

**推荐 B。** 依据：

- MaaCore 和游戏版本不兼容时，日常会在 `maa run` 里自己失败，战报上看得到。降级继续的代价是「可能白跑一场」，拒跑的代价是「一定不跑」。
- 真正危险的只有 §11.16 那种半更新状态，和「源被改了」。

更新本身的闸门（GUI 触发时）：

- 抢不到 `run.lock` 就不更新；
- 离 08:00 / 22:00 不足 `manual_run_blackout_minutes`（30 分钟）就不更新，免得占着锁撞上定时场。07:50 卡自己那一趟豁免；
- 游戏在跑不碍事，更新不碰游戏。

07:50 卡加锁后，「更新拖到 08:00 以后」会变成「08:00 日常抢锁失败」：按不变量 #23 要报失败，还会发 Discord。两种缓解，**需要用户定**：

- **B1**：08:00 日常发现锁被「更新」占着时，先等最多 N 分钟再判冲突。这要配合 Q3 的锁持有者标记，并修订 #23 的措辞；
- **B2**：把三步更新的超时总和压到 8 分钟以内（现在是 180 + 300 + 300 秒），超时就当本轮失败，按降级继续。

我倾向 B1，它和 Q3 是同一件事。

### (d) GUI 怎么触发和 07:50 完全相同的更新，又不复制一份

以后在 maa-remote 的 `remotectrl-supported-dev-1106` 分支上做，现在只写方案：

1. **抽出更新逻辑**：新建 `scripts/maa_upstream.py`，把 `read_maa_versions` / `upgrade_maa_cli` / `update_maa_core` / `update_hot_resources` / `check_and_update_upstream` 的「检查 + 更新 + 写回」部分搬过去，**发 Discord 的部分留在调用方**。`maa_plan_card` 改成调用它，行为不变：只有早场调（#40），失败发红卡、`raise`。`deploy.SCRIPT_NAMES` 和 `--check` 的名单加上这个新文件。
2. **两个入口**，`maa_action.py` 加：
   - `upstream status [--online]`：只读。默认离线，< 2 秒，输出 §6(b) 的判定和 §5 的信号。`--online` 再查 V2 / V5' / V7'，这时带代理，总预算 < 20 秒（不变量 #6）。`emit()` 现在只有 `ok` 和 `message`，要么加一个 `data` 字段，要么把 JSON 放进 message，并写进「外部消费者契约」（S2.8）。
   - `upstream update [--source gui|manual]`：立即返回，用 `Popen` 起一个脱离会话的 `maa_upstream.py update` worker，和 `run now` 一个模式。worker 依次：抢 `run.lock`（非阻塞）→ 过时间闸门 → 写「更新中」标记 → 跑原来那三步 → 写回 → 放锁。
   - GUI 每 2 秒轮询一次 `upstream status`，直到状态不再是 `running`。
3. **更新结果放哪**：放进新文件 `state/maa/upstream.json`，带 `schema_version`（不变量 #58）。内容：分步结果（`cli_ok`、`core_ok`、`core_changed`、`hot_ok`），前后的 Core 版本和 MaaResource HEAD，`source`，起止时间，`pid`。`last_run.json` 的 `resource_update_*` 照旧写，Discord 和战报不用改。不往 `config.json` 加新的运行时缓存键；万一要加，必须同时进 `PRESERVED_RUNTIME_CACHE_KEYS`（#25）。
4. **修 §2.5 的 brew 判断**，改用 `--json=v2`，单测的桩改成 brew 的真实退出码。
5. **代理和 PATH 有唯一来源**：
   - `config.json` 加 `upstream_proxy`（例如 `http://127.0.0.1:7890`）；
   - `maa_subprocess_env(keep_proxy=True)` 和 `_brew_env()` 在环境里没有代理时补上它；运行类子进程照旧剔除，不变量 #12 不变；
   - 同时补全 PATH，至少要有 `/opt/homebrew/bin`。否则 GUI 从 Finder 启动时，`shutil.which("brew")` 返回 `None`，`upgrade_maa_cli()` 会静默报「未找到 brew，跳过」。
   - GUI 只负责传 `HERMES_HOME`，其他都不管。
6. **定时场开跑前的离线检查**：`maa_daily.py` 抢到锁之后、`launch_game()` 之前，调一次离线的 `upstream status`，只认 (c) 里的两种硬拒（源被改了、不自洽）。被挡就写 `last_run`，发 Discord，退出。`now`（手动场）同样要查，这样「自动和手动都算」才成立。
7. **文档**：
   - DEV_GUIDE §3 第 1 步改成「调 `maa_upstream.update()`」；
   - 新增「外部消费者契约」一节：命令、JSON 字段、锁；
   - 不变量表加一条：**更新逻辑只有一份，在 `maa_upstream.py`，07:50 卡和 GUI 共用；更新期间持有 `run.lock`**，配 AST 或 grep 单测，确认全库只有这一个文件会调 `maa update` / `hot-update` / `brew upgrade`。

GUI 这边只剩：调命令、轮询、显示 §5 的信号、按 (c) 拦截。不写任何 brew / git / 下载逻辑。

---

## 7. 尚未确认的点

1. **`maa update` 换 dylib 的方式**：先写临时文件再 `rename`，还是原地覆盖。原地覆盖时，已经加载了这个 dylib 的 GUI 进程可能被内核以 Code Signature Invalid 杀掉。S0a 如果选了「GUI 进程直接链 maa-cli 的 dylib」，就必须搞清楚这一点。退路有两个：启动时把 `lib/` 按版本号拷一份到 App 私有目录再加载；或者坚持 (b) 的顺序，「先更新、再加载 Core，换了 Core 就重启 App」。
2. **哪些 maa-cli 子命令会刷新 OTA tasks**：已确认 `maa run` 会（日志第一行，加上 `.etag` 的时间）。`maa activity` / `update` / `hot-update` 会不会刷新 `tasks.json` 还没确认：`tasks.json` 的 mtime 是 11-05 07:50，正好是计划卡运行的时间，但分不清是哪一条命令写的。
3. **版本清单的确切 URL**：二进制里的前缀是 `https://api.maa.plus/MaaAssistantArknights/api/version/`，文件名推测是 `beta.json`。另外，`maa update` 下载 zip 是直连 GitHub 还是走镜像（`--test-time` 测速），也没确认。这关系到 V5' 能不能不带代理。
4. **maa-cli 0.7.5 → 0.7.8 的行为变化**：§2.5 一修好就会升级。DEV_GUIDE 里按 0.7.5 写的事实（任务文件格式、肉鸽 CLI 的限制、`--batch`、OTA 行为等）需要复核，并真机跑一场。
5. **Sparkle 会接受上游包**：这是按 Sparkle 2 的校验规则推出来的，没有实测。删掉 Sparkle 之后这个问题就不存在了，所以不打算实测。
6. **GUI 进程和 maa-cli 进程共用 `com.loong.maa` 作为 user dir 时**，`debug/asst.log`、`cache` 会不会互相干扰：归 S0a / S0c。
7. **GUI 链接的 Core 版本有多新还能兼容**：fork 的 Swift 代码是对着 2026-11 前后的 MaaCore 接口写的。maa-cli Beta 升到下一个次版本时，任务参数可能不兼容。建议在 fork 里记一个「已测 Core 区间」，V4 超出区间就只警告。区间本身要在 S3 里定。
8. **(c) 里 B1 和 B2 选哪个**，以及「新鲜」的阈值用 24 小时还是「本游戏日 04:00 之后」：需要用户定。
9. **`~/Documents` 有没有开 iCloud 同步、里面有没有 `resource` 目录**：没查，怕触发「文稿」权限弹窗。如果 §3.3 在去沙盒之前就拆掉，这一点就无所谓了。
10. **cron 暂停期间没有任何东西会更新 Core 和资源。** 上次是 11-06 07:50：Core 还是 v6.21.4，MaaResource 是 `99ad799f`。游戏要是在这期间更新，Discord 手动入口跑出来的日常可能失败。要不要在开发期手动更新一次，由用户决定。手动更新要在没有任何一场在跑时、带代理执行 `maa update --batch` 和 `maa hot-update --batch`。
