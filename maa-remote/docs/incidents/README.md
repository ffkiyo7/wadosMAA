# 事故记录

DEV_GUIDE 只写现行机制；这里放「当时出了什么事、怎么查出来的、为什么改成现在这样」。
每起事故一个文件，按 `YYYY-MM-DD-简短主题.md` 命名，时间一律北京时间。
新事故照这个格式加一个文件，并在下表登记；DEV_GUIDE 里需要来由的地方只留一句「见 incidents/xxx.md」。

| 日期 | 事故 | 一句话 | 不变量 |
|---|---|---|---|
| 2026-08-02 | [早场「返回主界面」空转报 Custom Error](./2026-08-02-home-quickswitch-custom-error.md) | `Custom` 里裸写 `QuickSwitch@ToHome`，`#back` 被丢掉，回到主页也判不了成功 | #5c |
| 2026-08-04 | [卸 BlueAI 把 BlueStacks 连同实例数据一起删光（模拟器时期）](./2026-08-04-bluestacks-cleanup-wiped.md) | BlueStacks 的清理 LaunchDaemon 发现三件套少一个就全删 | — |
| 2026-08-07 | [代理指挥失误被报成「掉落理智」、Fight 仍判完成](./2026-08-07-proxy-failure-sanity-refund.md) | TO-9 连续 4 批代理失误一关没打成，战报却写完成；由此加了失误判据、熔断和补跑 | — |
| 2026-08-08 | [MaaTouch 握手超 3 秒，MaaCore SIGSEGV，早场 35 秒暴毙（模拟器时期）](./2026-08-08-maatouch-sigsegv.md) | 模拟器冷启抖动让握手超时，maa-cli 不看 connect 返回值继续跑到段错误；由此加了连接阶段重开 | — |
| 2026-08-16 | [剥掉代理后 `maa update` 连不上 GitHub](./2026-08-16-maa-update-without-proxy.md) | 日常要剔代理、更新要带代理，两者混了导致更新超时、拖到下一周 | #12 |
| 2026-08-26 | [BlueStacks「有可用更新」弹窗卡死自动启动（模拟器时期）](./2026-08-26-bluestacks-upgrade-popup.md) | 弹窗不关 Android VM 就不启动，ADB 一直拒绝连接 | — |
| 2026-08-26 | [只跑 `maa update` 留下旧 MaaResource，MaaCore 启动即退](./2026-08-26-maaresource-out-of-sync.md) | MaaCore 包与热更新层必须一起前进 | #60 |
| 2026-09-01 | [宿舍确认条覆盖：两成一败，尚无 run 级实测](./2026-09-01-infrast-dorm-confirm-unverified.md) | 同一份极简覆盖 2026-09-01 三场两成一败，完整覆盖落定后还没跑过一场 | #4 |
| 2026-09-02 | [部署用仓库种子盖掉线上 `activity_stages`](./2026-09-02-deploy-overwrote-activity-stages.md) | 部署把正确的 `[]` 换成一个月前 TO 活动的关卡，直到下一次 watcher 才清掉 | #19、#25 |
| 2026-09-02 | [单测顺手打了真实的 prts.plus](./2026-09-02-unit-test-hit-prts.md) | 一条缓存 TTL 用例连真网，整套又慢又会被 SSL EOF 判红 | #43 |
| 2026-09-03 | [拿相邻顶层键当 YAML 锚点写坏 config.yaml，全部 cron 提前 8 小时](./2026-09-03-config-yaml-anchor-cron-8h.md) | Hermes 重排键顺序后提示词插进了 `skills:` 块，YAML 解析失败、时区回退 | — |
| 2026-09-07 | [`maa hot-update` 的 libgit2 后端无视代理，07:50 连续两天红卡](./2026-09-07-hot-update-libgit2-proxy.md) | hot-update 走 `cli.toml` 的 backend，libgit2 直连 GitHub；改成 `git` 后端 | #60 |
| 2026-09-08 | [删掉计划卡第三个下拉（材料缺口），改成后台自动定关](./2026-09-08-farming-select-removed.md) | 缺口天天变，下拉只能选关、显示不了缺口；2026-09-09 又改成降级期也自动定关 | #31 |
| 2026-09-09 | [早场主关空跑失败，后备关白挂到晚上](./2026-09-09-am-fight-dry-fallback.md) | SR-8 代理指挥没解锁、刷理智一颗没花，`farming_fallback_stage` 没人用；由此加了后备关补跑 | — |
| 2026-09-09 | [Hermes 把频道提示词折成两行，部署停住](./2026-09-09-config-yaml-folded-prompt.md) | 旧补丁按「单行带引号」整行匹配旧文案，找不到就抛错 | — |
| 2026-09-09 | [抄作业打完直接杀游戏，停在战后剧情，代理指挥锁着](./2026-09-09-copilot-killed-in-post-battle-plot.md) | SR-8 三星但没进结算页，早场日常 `UsePrts` 点不亮空跑；由此加了战后收尾 | — |
| 2026-09-09 | [逐关标记没 flush，战报全 ❓、同一批关被反复重打](./2026-09-09-copilot-log-marker-flush.md) | 标记落在本关输出之后，切出空段一律判 `unknown`；30 分钟退避一到又重打，由此加了当日上限 | #30、#33 |
| 2026-09-09 | [SR 账本种子一次都没跑，SR-5/6/8 被重抄](./2026-09-09-ledger-seed-skipped.md) | 种子只在「首次建账」时写，而账本早被上一个活动的 tick 建出来了；改成按 `seeded` 标记 | #30 |
| 2026-09-09 | [突袭切换真机验证失败](./2026-09-09-raid-switch-failed.md) | SR-5 普通详情页上根本没有突袭控件，`Custom(ChangeToRaidDifficulty)` 13 秒后 Error | #34 |
| 2026-09-09 | [手动抄资源本把当期活动账本归档掉](./2026-09-09-standalone-ledger.md) | 空 `activity_key` 让 `ensure_ledger()` 归档活动账本再新开，通关记录散进归档文件 | #52 |
| 2026-10-11 | [自动作业空转 17 轮：森空岛过期，YW-4 反复开游戏又关](./2026-10-11-yw4-prefight-loop.md) | 刷新失败沿用过期缓存照排、开打前环境故障不记账，永远到不了当日上限 | #55 |
| 2026-11-02 | [游戏 26.11.1 主页改版，主页标识和入口全认不出](./2026-11-02-home-theme-template.md) | MaaCore 停在旧版、三丽鸥主题入口认不出就切主题；由用户资源层接管 9 个入口 | #59 |
| 2026-11-03 | [本机 ADB 换成 Landship 库内那份（模拟器时期）](./2026-11-03-adb-landship-path.md) | 路径不能带空格，BlueStacks 的 `hd-adb` 弃用 | — |
| 2026-11-04 | [单测靠真实 `~/.hermes` 才绿，还往线上状态里写东西](./2026-11-04-unittest-isolation.md) | 干净 HOME 下红 24 条、留下几百个备份目录、拿真 token 打森空岛；共享临时 HOME 互相污染；系统 3.9 写 pycache | — |
| 2026-11-04 | [整套单测真的开关了一次游戏](./2026-11-04-unittest-touched-real-game.md) | Depot 用例桩在 `maa_daily.launch_game` 上，实际调的是 `maa_playcover.launch_game` | — |
| 2026-11-05 | [点击落进顶栏，弹出「纯源石兑换合成玉」](./2026-11-05-originite-exchange-popup.md) | MaaCore 在匹配框里随机取点，三丽鸥终端模板贴着顶栏；入口模板加 `rectMove`、弹窗只点 ✗ | #59 |
| 2026-11-05 | [晚场全程 ScreencapFailed：游戏从物理屏台前挪走后截不到](./2026-11-05-pm-screencap-failed.md) | 显示器开着，游戏开在 Q24G2 上，winmove 挪向 MAA-Game 后台前调度把它收走；由此加了窗口恢复和缩略图识别 | — |
| 2026-11-07 | [活动监控 cron 暂停，抄作业页一直列上一期活动、新活动整页 no_nav](./2026-11-07-paused-watch-stale-activity.md) | 当期活动只认 `activity_watch.json`，游戏数据刷新排在暂停判断之后 | — |
| 2026-11-08 | [早场全程 ScreencapFailed：游戏在 MAA-Game 上被收成侧边栏缩略图](./2026-11-08-am-window-shelved.md) | 游戏一直是前台，`open -a` 无效，摆窗 8 次全失败，重开闸门又被 `AllTasksCompleted` 骗过 | — |
| 2026-11-09 | [早场整场 GameOffline：游戏没登录上](./2026-11-09-am-game-offline.md) | 「获取网络配置失败」弹窗点确认不会重拉配置，只有重启进程才行 | #61 |
| 2026-11-10 | [游戏热更新挪了首页面板，三丽鸥终端 / 任务入口认不出](./2026-11-10-sanrio-home-layout-shift.md) | 11-08 热更新换了首页布局，11-02 截的入口模板对不上；重截 9 张，避开会动的条纹和半透明云朵 | #59 |
| 2026-11-25 | [手动场卡在「启动游戏」：游戏中途退出，MaaCore 不会重连](./2026-11-25-now-game-exited.md) | 摆窗救场用 `open -a` 把退出的游戏重新拉起，MaaCore 却连着旧进程，截图全是 Broken pipe | #68 |
