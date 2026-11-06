# Wado's MAA：fork MaaMacGui，接管 maa-remote 的日常配置与手动运行

> 写于 2026-11-06，同日按用户答复改写。**只有方案，不含实现代码。**「待确认」那几条定下来、spike 回来之前不开工。
> 上游现场以 MaaMacGui `b2c99a8`（2026-11-03）为准。maa-remote 线上 `~/.hermes/scripts/` 与仓库 `scripts/` 已 `cmp` 过，两边一致。

## 目标（用户 2026-11-06 的五条要求）

1. **我们有、上游没有的功能都做进 GUI**，做成可调的开关或选项。在 GUI 里就能调日常的配置，不用再去 Discord 找 Hermes 或点按钮。
   - Discord 频道里的按钮**保持不变**。
   - 两边配置**必须同步**：手机上在 Discord 点过的，日常就按 Discord 的执行，不能还按 GUI 里的旧值跑。
2. **跟上游走的东西**（游戏资源、MaaCore）：更新源要**钉住**，并且保持**自动更新**。自动任务开跑前、GUI 被手动打开后都要检查；maa-remote 原来的更新源和 GUI 的不一致时，要处理冲突。
3. **仓库和线上**：
   - 卸掉本机的官方 MAA.app。
   - fork 放在 `~/Developer/forks/` 下，是一个新仓库，远端以后由用户自己配。
   - **在用户确认全部功能跑通之前，不动 maa-remote 原仓库，也不动 cron 用的配置**；cron 先暂停。
4. **外观和签名**：
   - 支持自定义 UI 背景图；
   - 窗口外壳改成 Liquid Glass 风格；
   - 最低系统版本改为 macOS 26；
   - 用自己的 Xcode 开发证书签名（免费账号，不做公证）。
5. **分支**：全部改动都在分支 `remotectrl-supported-dev-1106` 上做。

---

## 已定决策（2026-11-06）

| # | 决策 |
|---|---|
| K1 | **开发期用状态副本**：把 `~/.hermes/state/maa/` 复制到 `~/Developer/forks/maa-remote-devhome/`。GUI 和它调用的脚本都带 `HERMES_HOME=<devhome>`（`maa_common.HERMES_HOME` 读这个环境变量）。线上一字不碰；和 Discord 的同步，到 S7 切回线上后再验。 |
| K2 | **maa-remote 这边的改动**在 maa-remote 仓库里用 worktree 开同名分支 `remotectrl-supported-dev-1106`：不合进 main，不跑 `deploy.py`，S7 验收通过后再合并、部署。 |
| K3 | **同步规则**：状态只有一份，就是 maa-remote 的状态文件，GUI 不存副本，文件一变就重读。两边谁后改就以谁为准，界面上标明「几点由 GUI / Discord 改」。GUI 改了某一场的计划，Discord 上已经发出去的那张计划卡也跟着刷新。 |
| K4 | **日常配置合成一份**：GUI 的「一键长草」页改成编辑 maa-remote 的配置；点开始，跑的是 maa-remote 的流程（`run.lock`、窗口摆放、主页截图核验、Discord 战报）。上游的任务列表隐藏。fork 的 App 要单独授一次「辅助功能」权限，否则挪不了游戏窗口。 |
| K5 | **配置项全做**：每场计划、日常细项、自动定关、活动自动抄作业、肉鸽、森空岛、仓库对表、运行环境。**上游的同类选项去掉，换成我们的。** |
| K6 | **早晚场时间可以在 GUI 里调**，也可以关掉某一场的 cron。 |
| K7 | **更新源先做 spike**（S0a / S0b），不预设结论。方向是只认 maa-cli 这一个源。 |
| K8 | **App 身份**：显示名「Wado's MAA」，bundle id `io.github.ffkiyo7.MaaRemoteGui`；去掉沙盒，删掉 Sparkle，用 `Apple Development: ffkiyo7@gmail.com` 签名。上游的「定时一键长草」入口隐藏，`TaskTimerManager` 不启动。 |
| K9 | **Liquid Glass 的范围**：侧栏、工具栏和各页的卡片容器改成玻璃材质，内容区里的控件不改。**背景图**：整个窗口一张，从本地选文件，浅色和深色模式可以各设一张，填充方式、遮罩和模糊程度都能调。 |
| K10 | **官方 MAA.app 留下的数据**：配置目录 `~/Library/Containers/com.hguandl.MeoAsstMac` 先保留。fork 第一次启动时让用户选择要不要导入之前的任务配置，确认没用后再删。 |

### 第二轮决策（2026-11-06）

| # | 决策 |
|---|---|
| K11 | **GUI 里不提供任何降级开关。** 不碎石、只吃临期药、不借助战、不忽略练度，maa-remote 的不变量 #1 / #2 / #15 原样保留。上游页面里的同类选项（碎石、吃药、助战等）也一并移除。 |
| K12 | **GUI 的「一键长草」和 maa-remote 的日常走同一条执行路径**：`maa_daily.py now <token>`，同样持锁、摆窗口、截图核验、发 Discord 进度和战报。GUI 只是把「这一次」的参数调得更方便：刷哪关（选项来源和计划卡相同，都是 `_stage_choices()`），哪些环节跳过（`tasks.fight` / `infrast` / `recruit` / `mall` / `award`，以及剿灭开关，见不变量 #26）。这些参数只对这一次手动场生效，不写进 `plan.json`，规则同手动场决策 M4。早晚场的计划和持久默认值在别的页面改。 |
| K13 | **「自动战斗」页新增我们的自动抄作业入口**，流程如下：<br>1. 扫当前开放、能导航过去的关，列成列表（数据源同 Discord 抄作业卡 `copilot_card_stages()`）；<br>2. 用户选一关，GUI 去 prts 搜作业，展示搜到的全部作业，并标出每份缺什么；<br>3. 只有完全满足练度、没有任何缺口的作业能选（不变量 #15 / #18）；<br>4. GUI 自动选中最优的一份，**用户点「确认开打」才派发**（2026-11-06 用户改为多一步确认）。<br>派发前过同一个闸门 `dispatch_blocker()`；打的过程中可以「取消本轮」。上游手动贴作业码的功能保留。 |
| K14 | **肉鸽用上游的**（照样要先抢 `run.lock`）。maa-remote 自己的肉鸽**整套删掉**（K16）。 |
| K15 | **锁持有者标记**（原 D1 的 A+）：谁拿到 `run.lock` 就往锁文件里写一行持有者。定时场被挡住时，Discord 上会说「Wado's MAA 正在用」，而不是报一个锁冲突失败。这是 maa-remote 分支上的改动。 |

### 第三轮决策（2026-11-06）

| # | 决策 |
|---|---|
| K16 | **maa-remote 的肉鸽整套删掉**：`maa_roguelike.py`、`maa_roguelike_worker.py`、`maa_action` 里的 `roguelike *` 命令、Discord 肉鸽卡和它的按钮前缀、`roguelike.json` 及其 schema 常量、SKILL.md 里的肉鸽部分、对应单测，以及不变量 #46–#50。DEV_GUIDE §5.7 改成一句「已移除，改用 Wado's MAA 里的上游肉鸽」。线上残留的 `roguelike.json` 和登记表里的 `hermes:btn:maa-roguelike:*` 在 S7 部署时清掉。 |
| K17 | **07:50 的更新持有 `run.lock`；拖过 08:00 时，日常等更新跑完**。日常抢不到锁时，先看 K15 写的持有者：如果是「更新」，就阻塞等待，并设一个上限（具体值待定，要在 `maa_run_timeout` 的预算里留出来），等到了再照常开跑；持有者不是「更新」，仍然走现有的锁冲突处理（不变量 #23）。 |
| K18 | **「已经更新过」的标准是本游戏日（北京时间 04:00 之后）成功更新过一次**，不是 24 小时内。 |
| K19 | **maa-cli 升级 bug 放进 maa-remote 开发分支，跟 `maa_upstream.py` 一起修**：`brew outdated` 有新版本时退出码是 1，`upgrade_maa_cli()` 把它当成了失败，所以 maa-cli 一直停在 0.7.5（11-06 早场的 `resource_update_status=failed` 已核实）。S7 上线前用新版 maa-cli 真机跑一场，再更新 `verified_versions.json`。 |
| K20 | 更新源方案按 S0b 报告推荐的来：GUI 关掉自带的四条联网更新路径，改读 maa-cli 的资源层；开跑前做离线检查；不一致时分级处理；更新逻辑抽到 `maa_upstream.py` 里两边共用；`maa_action` 加 `upstream status` / `upstream update`。最终形态还要看 S0a 的结论。 |

## 待确认

暂无。

## 进度（2026-11-06 15:00 北京时间）

S1–S6 已实现，两边都提交在 `remotectrl-supported-dev-1106` 上，**都没 push**。S7 由用户来做。

| 步骤 | 提交 | 验到哪一步 |
|---|---|---|
| S1 fork 骨架 | fork `ddd084f` `2103f5f` `485c2d1` `0fe458d` `7e2d7d9` `86070dd` | Release 构建、签名（Apple Development，Team DY725KK25V，带 disable-library-validation）；在 devhome 上启动过：Core 从 maa-cli 的 `lib/` 加载（v6.21.4），资源按 maa-cli 的层加载 |
| S2 maa-remote | maa-remote `f88712b` `17b73a0` `77e2191` `12c7cf8` `298aa52` `1e09eef` `f7a0406` `8f58db6` `dca86a3` `020ed4b` | 727 个单测在 py3、`/usr/bin/python3`、干净 HOME 下都过，ruff、pyright 干净；`upstream status`、`config get`、`schedule show`、`run choices`、`copilot stages` 在 devhome 上手跑过 |
| S3 互斥和版本检查 | fork `3ad60b0` | 构建通过；启动检查在 devhome 上实跑：判定 stale，更新被「开发副本只检查」挡住。抢锁、挡定时场的那段要连游戏才走得到，**没实跑** |
| S5 配置页 / 状态 / 同步 | fork `b8234bb` | 构建通过；启动后 App 在监听 devhome 的 `state/maa/` 和 `cron/`。界面**没点过** |
| S6 一键长草 / 自动战斗 | maa-remote `020ed4b` + fork `99ecd88` | 构建通过；两条列表命令在 devhome 上能出结果。开一场、派一轮作业**没实跑** |
| S4 外观 | fork `10ba690` | 构建通过；视觉效果**没看过** |

S0d 的进展：
- GUI 进程调 `maa_action.py` 能拿到回执：已验，App 启动时就调了 `upstream status`；
- `hermes cron` 认 `HERMES_HOME`：读已验，写没测；
- GUI 的 flock：代码就绪，没实跑。

### 界面重设计（分支 `claude/redesign-ui-60930c`，2026-11-06 17:30 北京时间）

按定稿原型（https://claude.ai/artifact/S3SiwmWqxS7i8SGKTHNbRK）重写界面，代码在 `MeoAsstMac/Remote/Redesign/`，`ContentView` 换成 `RedesignRoot`。功能和底层调用不变。S7 上线后再合并。

| 页 | 提交 | 状态 |
|---|---|---|
| 主题、⚡ 确认框 | `057a959` | 构建通过 |
| 今天（手动开一场｜定时场、游戏锁、版本；抄作业关卡；最近一场） | `87fc80b` | 构建通过 |
| 自动抄作业（三栏，确认开打不绑回车、先弹确认） | `cd3f41d` | 构建通过 |
| 日程与默认 | `b40d5ef` | 构建通过 |
| 日常配置（日常 / 高级，整页保存，逐项 `config set`） | `63af079` | 构建通过 |
| 工具与更多（肉鸽、生息演算、任务列表、手贴作业；实用工具） | `9b5634e` `1ec582f` | 构建通过 |
| 设置（强调色、maa-remote 环境、连接与游戏） | `df80595` | 构建通过 |
| 边栏、状态条、日志检查器 | `d775527` | 构建通过 |

还没做 / 没核对：
- 逐页截图已对照（截图在 `~/Developer/forks/wados-maa-build/redesign/shots/`）；⚡ 确认框、候选作业列表、编辑弹窗没截到
- 状态条的「停止」只对本 App 里跑的上游任务有效。maa-remote 的 `run local` 没有停止接口，这次没加；
- 原型里的「自动定关」开关、「今天已试 n/2」「距离下一场」没有现成接口，没放；
- 「最近几场」只有 `last_run.json` 这一场；
- 只做了深色外观。

### 要真机的（先问用户要时间）

- **S0c**：两个 Core 同时连一个 MaaTools。
- S3 的抢锁、定时场确认、Core 换了要重启这几条路径。
- S6：
  - GUI「开始这一场」→ `run local` → 一场完整日常（Discord 的部分在 devhome 里没有 token，发不出去）；
  - 自动抄作业预览 → 确认开打 → 取消。
- maa-cli 0.7.5 → 0.7.8：K19 修好后，线上第一次 07:50 就会升级。升完要真机跑一场，再更新 `verified_versions.json`。

### 要用户在系统里点的

- fork 的 App 单独授「辅助功能」（K4，挪游戏窗口用）。
- 第一次启动的旧配置导入（K10）要读官方 MAA 的容器，macOS 可能弹「访问其他 App 的数据」。

### S7 检查单（在上面「S7 切到线上验收」之外补的）

- maa-remote：合进 main 并部署，`SCRIPT_NAMES` 新增 `maa_upstream.py`、`maa_schedule.py`、`maa_settings.py`；清掉线上残留的 `roguelike.json` 和 `hermes:btn:maa-roguelike:*`。
- 线上 `config.json` 可以加 `upstream_proxy`（例如 `http://127.0.0.1:7890`），GUI 从 Finder 起时就有代理。
- GUI 设置 →「maa-remote」把 HERMES_HOME 改成 `~/.hermes`。开发副本里的 `scripts` 是指向 `maa-remote-dev/scripts` 的软链，切走后就不用了。
- 恢复 cron 前，在 GUI「场次」页确认四条任务的时间都对齐（`in_sync`）。

---

## 已完成的准备（2026-11-06 11:49 起）

- **暂停的 cron**（`hermes cron pause`，恢复用 `hermes cron resume <id>`）：
  - `03d5e98ce8d4` 计划卡·早
  - `75e3d662fbfc` 计划卡·晚
  - `50cd1fb095f2` 日常·早
  - `4f48cf619d9f` 日常·晚
  - `b2f15f13589f` 仓库对表
  - `3ba48fb85d0b` 活动作业监控：在这之前就已经是暂停状态

  网关仍在运行，Discord 按钮和聊天「现在跑」**仍然能触发运行**。07:50 早场卡负责的 Core / 资源更新也一起停了。
- **官方 MAA.app**（v6.21.0-beta.3）已移到废纸篓，配置目录保留（K10）。
- **fork**：`~/Developer/forks/MaaMacGui`，上游远端改名为 `upstream`，没有 origin，开发分支 `remotectrl-supported-dev-1106`。
- **maa-remote 仓库**：工作区干净，这份文档已从那里挪到这里。

## 本机环境

macOS 26.6、Xcode 26.6，钥匙串里有一张签名身份 `Apple Development: ffkiyo7@gmail.com`，没有描述文件。

---

## 现场摸底（上游 `b2c99a8`）

| 事实 | 出处 | 对方案的影响 |
|---|---|---|
| MaaMacGui 是主仓库的 submodule，工程从 `../../build/MaaCore.xcframework` 引用 MaaCore | `README.md`、`project.pbxproj` | Core 从哪来，由 S0a 定 |
| 子仓库根目录没有 LICENSE，按主仓库 AGPL-3.0 处理 | 仓库根目录 | fork 只能用 AGPL；maa-remote 保持 MIT，不收任何 Swift 代码 |
| 开着 App Sandbox；正式版还带 `keychain-access-groups` | `*.entitlements` | 去掉沙盒（K8）。免费账号没法长期维持描述文件，所以要去掉一切需要描述文件的权限 |
| 用 Sparkle 自动更新 | 工程依赖 | 删掉（K8） |
| 自带「定时一键长草」（`TaskTimerManager`）：只在 App 开着时生效，到点时 GUI 空闲就按一下一键长草；Mac 睡过了点不补跑 | `Utils/TaskTimerManager.swift` | 隐藏（K8）。调度只认 cron，在 GUI 里调 cron（K6） |
| 八个执行入口都先过 `MAAViewModel.ensureHandle()`，其中只有视频识别不连设备 | `Model/MAAViewModel.swift` | 上游手动功能的锁闸门就放在这一处 |
| 运行状态是 `status ∈ idle / pending / busy` | 同上 | 回到 `idle` 时放锁 |
| 连 PlayCover 走 MaaTools `127.0.0.1:1717`；开游戏是打开 PlayCover 容器里的 `.app` | `ensureHandle()` / `startGame()` | 和 maa-remote 抢的是同一个游戏 |
| 上游正在重构 ViewModel（`NewViewModel.swift`） | `Model/NewViewModel.swift` | 挂钩点尽量少 |
| GUI 用自带的 Core 和资源（OTA 更新），不读 maa-cli 的用户资源层 | `MAAViewModel.loadResource*` | 不变量 #59（三丽鸥主题）、#4（宿舍确认条）的修复在 GUI 里不生效；S0a / S0b 处理 |
| 官方 App 带的是普通 dylib，和 maa-cli 的 `com.loong.maa/lib/` 是同一套文件名、同一组第三方版本 | 本机 `ls` | 直接链 maa-cli 那份 Core 有可能成立（S0a） |
| maa-cli：Core 走 `Beta` 通道，资源用 git 后端，`auto_update = false`，每天 07:50 由早场计划卡统一更新 | maa-remote `config/maa-cli/cli.toml` | 「钉住的源」的候选（S0b） |

---

## 分步

格式沿用 maa-remote `docs/PLAN_MANUAL_RUN.md`。

### S0 spike（S0c 待真机）

| 编号 | 内容 | 要不要开游戏 | 状态 |
|---|---|---|---|
| S0a | fork 能不能链接、加载 maa-cli 那份 Core 和资源 | 不用 | **已完成，有条件可行**。报告：`docs/spikes/2026-11-06-core-from-maa-cli.md`，推荐改法的 diff：`…recommended.diff`。条件见 S1 |
| S0b | 两边的更新路径对照、要比对的版本信号、冲突怎么处理（只读） | 不用 | **已完成**，报告在 `docs/spikes/2026-11-06-update-source.md`，结论见待确认 Q5–Q7 |
| S0c | 两个 Core 同时连一个 MaaTools：GUI 空闲但 handle 还连着时，maa-cli 能不能连上、截图、点击 | 要，不耗理智 | 等用户给时间 |
| S0d | 从 GUI 进程用 `flock` 抢同一把 `run.lock`；GUI 进程调 `maa_action.py` 能不能拿到回执；`HERMES_HOME=<devhome>` 下 `hermes cron` 读写的是不是副本 | 不用 | **大部分已验**：回执已验，cron 读已验；flock 和 cron 写还没实跑（见「进度」） |

### S1 fork 骨架

- 按 K8 改 App 身份、去沙盒、删 Sparkle、关定时器；
- 部署目标改为 macOS 26.0，用开发证书签名；
- Core 按 S0a 的结论接入。S0a 实测：
  - 版本：maa-cli v0.7.5 / Core v6.21.4；
  - 两份 Core 是同一次构建，5 个 dylib 的 LC_UUID 一致，我复核过；
  - 导出的 28 个 `_Asst*` 符号两边完全一致。

  具体要做的：
  - **链接方式**：头文件取 tag v6.21.4，加 modulemap 和一个只列 `_Asst*` 的 `.tbd` 存根，用弱链接（`-weak-lMaaCore`）。rpath 指向 `$(HOME)/Library/Application Support/com.loong.maa/lib`，dylib 不拷进 App 包。
  - **库验证**：Release 的 entitlements 必须加 `com.apple.security.cs.disable-library-validation`，否则 dyld 会以 Team ID 不同为由中止。Debug 用 ad-hoc 签名时测不出这个问题，**验收一律用 Release**。
  - **资源路径**：GUI 里读 App 包内 `resource/` 的几处都改到 maa-cli 的目录。加载顺序和 maa-cli 一样：base → MaaResource → 热更新缓存 → `~/.config/maa-cli/resource` → `platform_diff/iOS`。
  - **启动预检**：dylib 存在、`AsstGetVersion()` 等于盘上记录的版本、和 `upstream status` 的结论一致。`maa update` 会先删掉整个 `lib/` 和 `resource/` 再解压；弱链接能扛住这个窗口，但要给出提示。
- **去沙盒之前必须先改两处**：
  - Debug 构建每次启动都会删 `<Documents>/resource`（`MAAViewModel.loadResource(channel:)`），去沙盒后就是 `~/Documents/resource`。整段删掉。
  - Core 的用户目录（`MAAViewModel.userDirectory`）去沙盒后会变成 `~/Library/Application Support` 根目录，要改成 `~/Library/Application Support/io.github.ffkiyo7.MaaRemoteGui/`。
- 删掉 Sparkle 的依赖，以及 `Info.plist` 里的 `SUFeedURL` / `SUPublicEDKey`。佐证：废纸篓里那份官方 App，今天 11:44 已被 Sparkle 自动从 beta.3 升到 v6.21.4。

### S2 maa-remote 分支（K2）

1. **配置读写命令**：`maa_action` 加 `config get` / `config set`，键用白名单，值逐项校验，校验规则和渲染器（不变量 #44、#51）共用一份。
2. **场次时间和 cron 开关**（K6）：早晚场时间从配置读，不再写死 08:00 / 22:00，用到它的地方都要改：计划卡提前 10 分钟、各处 blackout、`min_lead`。改时间时同步更新 `hermes cron`。
3. **本地手动场**（K4、K12）：
   - 新增 `run local`，不发 Discord 选关卡，直接按 GUI 给的关和环节开关派发；
   - 参数写进 `manual_run.json`（新增 `tasks` 覆盖），`maa_daily.py now <token>` 读出来用；
   - 仍然要持 `run.lock`，仍然受「定时场优先」约束；
   - Discord 照常发开跑消息和战报。
4. **计划卡刷新**：GUI 改了某一场的计划，Discord 上的计划卡跟着 PATCH（K3）。
5. **持久默认值**：`defaults.json` 现在没有写入口，要加 `defaults set`，并带校验。
6. **抄作业预览**（K13）：
   - 新增 `copilot preview <关>`：只搜不派发，返回全部候选（是否完全满足、缺口）和一个 token。搜索要 5～20 秒，所以只给 GUI 用，不进 Discord 的 20 秒回执路径（不变量 #6）；
   - 新增 `copilot go <token>`：过 `dispatch_blocker()` 后，按预览里选中的完全满足的那份派发。
7. **更新**（K17–K20）：
   - 新建 `maa_upstream.py`，加 `upstream status [--online]` / `upstream update` 两个命令，分步结果写进 `upstream.json`（带 `schema_version`）；
   - 07:50 的更新改为持锁执行；
   - 修好 `brew outdated` 退出码的 bug；
   - 「已经更新过」按游戏日判断。
8. **锁持有者标记**（K15），再加上「持有者是更新时，日常等它跑完」（K17）。
9. **删掉 maa-remote 的肉鸽**（K16）。
10. **文档**：DEV_GUIDE 加一节「外部消费者契约」，写明 Wado's MAA 依赖的字段、锁路径、命令；不变量表加 #60。

**验收**：`python3 -m unittest discover -s tests` 全部通过；ruff 和 pyright 都 0 报错。

### S3 fork：互斥和版本检查

- 上游手动功能：在 `ensureHandle()` 前抢锁，回到 `idle` 时放锁；
- GUI 启动时、每次开跑前做版本检查（按 S0b 的结论）；
- 定时场前 30 分钟内拒绝开跑，可以确认后强行开跑。

### S4 fork：外观（K9）

Liquid Glass 外壳、背景图设置（浅色 / 深色各一张，填充方式、遮罩、模糊程度）。

### S5 fork：配置页、状态面板和同步（K3、K5、K6）

- 全部配置项都做成页面；
- 状态面板；
- 文件一变就重读；
- 每项标明「由谁、几点改的」；
- 读每个文件都校验 `schema_version`（不变量 #58）。

### S6 fork：一键长草和自动战斗换成我们的流程（K4、K11–K14）

- **一键长草**：隐藏上游任务列表，改成「这一次」的关卡和环节开关，开始按钮调 `run local`。
- **自动战斗**：新增「自动抄作业」入口，走「选关 → 预览候选 → 自动选中 → 点『确认开打』→ 派发」，调 `copilot preview` / `copilot go`。
- 上游手动贴作业码、肉鸽都保留，开跑前先抢锁。
- 上游页面里的碎石、吃药、助战选项全部移除。

### S7 切到线上验收

1. maa-remote 分支合进 main 并部署；
2. GUI 的 `HERMES_HOME` 改回线上；
3. 恢复 cron；
4. 真机验一遍：Discord 和 GUI 两边互改都能同步，定时场、手动场、锁冲突都正常；
5. 用户确认。

---

## 风险

- **跟上游**：上游重构 ViewModel 期间，挂钩点很可能挪位置；MAA 发版很勤。
- **Core 共用**（如果 S0a 成立）：maa-cli 一换 Core，GUI 也跟着换，可能出现 ABI 不兼容。S3 的版本检查要能接住这种情况。
- **辅助功能权限**：要单独授给 Wado's MAA。签名身份一变，系统会要求重新授权。
- **cron 暂停期间**：不会自动更新，也没有日常。Discord 的手动入口还开着，GUI 开发期间要避免和它撞车。
