# Phase 4 子 Spec：无线自动续签 + P2 完善

> 对应总 Spec：[SPEC_DECOUPLE_AND_IOS.md §6.4 & §7 & §9 Phase 4](../SPEC_DECOUPLE_AND_IOS.md)
> 前提：Phase 3 生产切线（S3-7）已稳定运行，且 Phase 0 S0-1 已实证无线续签 `ExpirationDate` 后移机制成立。

---

## 执行顺序与并行安排

```text
S3-7 切线稳定
  ├──► S4-1 (Mac 侧无线自动续签引擎 maa_ios_resign.py)   [并行]
  ├──► S4-2 (iOS 快捷指令个人自动化模板)                   [准备并行，实测接 S4-1]
  ├──► S4-3 (iOS「设置」Tab P2 完善：续签/调度器/高级配置) [完全并行]
  └──► S4-4 (TLS 证书到期告警与双指纹零中断轮换演练)       [并行]
         │
         ▼
  S4-5 (Phase 4 端到端终验)
```

---

## S4-1：Mac 侧无线自动续签引擎（`maa_ios_resign.py`）

- **前置依赖**：S3-7（+ S0-1 结论）
- **并行性**：🟢 与 S4-2 / S4-3 / S4-4 可并行
- **新增 / 改动文件**：
  - `maa-remote/scripts/maa_ios_resign.py`
  - `maa-remote/scripts/maa_daemon.py`（接入 25 分钟自动探测周期与真实 `POST /api/v1/ios/resign?if_due=1`）
  - `maa-remote/tests/test_ios_resign.py`
- **规格要点**：
  1. **状态落盘 `daemon/resign.json`**：记录 `last_signed_at`、`expiration_date`、`status`（`ok`/`due`/`running`/`failed`）、`last_attempt_at`、`last_error`、`log_summary`；
  2. **待续签判定（`due`）**：距上次成功签名满 5 天（120h）或距 `ExpirationDate` 不足 48 小时；带 `?if_due=1` 且未到期时直接返回 `ok=true, code="not_due"`；
  3. **自动探测 4 条件（每 25 分钟检查）**：
     - 局域网 iPhone IP（配置于 `daemon.json`，如 `192.168.50.201`）可达；
     - `xcrun devicectl list devices --json-output -` 确认目标 UDID 在线；
     - `run.lock` 当前空闲；
     - 最近 2 分钟无来自 iOS App 的活跃 API 请求；
  4. **执行与核验**：
     - 持独立 `daemon/resign.lock` 防并发；
     - **构建源硬锁定 `~/Developer/wados-maa-deploy/ios/WadosMAAiOS.xcodeproj`**（固定 `main` 分支，绝不使用 `dev` 或开发 worktree），独立 `derivedData` 增量构建；
     - **S0-1 实证必做前置**：构建前必须先移走本地缓存的 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/<OLD_UUID>.mobileprovision`（备份至临时目录），再执行 `xcodebuild -allowProvisioningUpdates`，否则 Xcode 会复用旧 Profile 导致 `ExpirationDate` 不后移；
     - 解析产物 `.app/embedded.mobileprovision` 校验新 `ExpirationDate` 严格晚于旧值（否则判失败不覆盖状态）；
     - 执行 `xcrun devicectl device install app --device <UDID> <App包路径>` 无线覆盖安装；
  5. **通知与告警**：
     - 成功：更新 `resign.json`，发 `passive` Bark（`id=ios-resign`）「已自动续签，有效期至 MM-DD」；
     - 暂时失败（锁屏/离线超时）：记日志静默等待下个周期；
     - **第 6.5 天仍未成功**、识别到 Xcode Apple ID 过期、或 `ExpirationDate` 未后移：发 `timeSensitive` Bark 告警。
- **验收清单**：
  - [ ] 状态机、4 条件守卫、锁死 `main` 路径、`ExpirationDate` 核验与告警阈值离线单测全绿
  - [ ] `POST /api/v1/ios/resign?if_due=1` 同时支持 `full` 与 `resign_only` Token

---

## S4-2：iOS 快捷指令个人自动化模板

- **前置依赖**：S3-7（实测联调等 S4-1）
- **并行性**：🟢 与 S4-1 / S4-3 / S4-4 并行
- **交付内容**：
  - 在 `docs/specs/` 或操作说明中沉淀快捷指令配置步骤：
    - 触发器：个人自动化 → 接入家庭 Wi-Fi（`Alice3u3` / `Aliceuwu`）→ 立即运行（关闭运行前询问）；
    - 动作：`获取 URL 内容` → `POST https://maa.luxraykit.com/api/v1/ios/resign?if_due=1` → Header `Authorization: Bearer <resign_only_token>`（公网标准 HTTPS 证书，避免快捷指令拒绝自签证书）。
- **验收清单**：
  - [ ] 未满 5 天连 Wi-Fi 静默返回 `not_due` 无打扰
  - [ ] 模拟 `due` 状态连 Wi-Fi 触发自动续签成功

---

## S4-3：iOS「设置」Tab P2 完善

- **前置依赖**：S3-7（所有配置与调度 API 已在 Phase 2 就绪）
- **并行性**：🟢 与 S4-1 / S4-2 / S4-4 完全可并行
- **改动目录**：`ios/` 设置页与高级设置二级页
- **功能范围（对齐 §6.3 & §6.4）**：
  1. **iOS 签名与无线续签卡片**：展示上次签名时间、Profile 到期倒计时、上次续签结果、「立即无线续签」按钮（局域网直连时可用）；
  2. **内置调度器卡片**：展示 6 条任务（`plan_card_am`/`daily_am`/`plan_card_pm`/`daily_pm`/`depot`/`activity_watch`）的下次运行时间与上次状态，提供 `depot_enabled` 独立启停开关（默认关闭）；
  3. **高级设置二级页（默认收起防误触）**：
     - 代理指挥熔断（`proxy_failure_limit`、`proxy_failure_salvage`）；
     - 自动定关算法（`farming_weights`、`farming_min_samples`、`farming_target_days`、`farming_activity_edge`、`farming_rerun_days`、`farming_scarcity_horizon_days`、`farming_stage_table`、`farming_manual_weights`，含移动端键值表增删行编辑）；
     - 森空岛（仅 `skland_roster_refresh_days`，绝不提供 token 录入）；
     - 运行参数（超时与重试 10 项）；
     - Mac 主机窗口行为（`game_display_name`、`disable_stage_manager_during_run`，带主机提示折叠展示）。
- **验收清单**：
  - [ ] 全部 `maa_settings.FIELDS` 白名单项可正确校验、保存并回显 `iOS` 修改来源
  - [ ] 严守边界外红线：无任何降级开关、无森空岛 token 入口、无底层路径配置

---

## S4-4：TLS 证书到期告警与双指纹零中断轮换演练

- **前置依赖**：S3-7
- **并行性**：🟢 与 S4-1 / S4-2 / S4-3 可并行
- **演练步骤**：
  1. 触发模拟「证书距到期 < 60 天」巡检，确认收到 `timeSensitive` Bark 告警（`id=tls-cert`）；
  2. 生成新自签证书，先将新 SPKI 指纹填入 iOS App 的「备用指纹」槽位；
  3. 在 Mac mini 替换 `~/.wados-maa/daemon/tls/cert.pem` + `key.pem` 并重载 `wados-maa-daemon` 与 `wados-maa-cloudflared`；
  4. 确认 iOS App 在局域网与 5G 两条链路下均无报错无缝继续工作，再将新指纹提升为主指纹。
- **验收清单**：
  - [ ] 60 天到期告警触发正常
  - [ ] 双指纹零中断轮换演练全程无断链报错

---

## S4-5：Phase 4 端到端终验

- **前置依赖**：S4-1, S4-2, S4-3, S4-4
- **并行性**：🔴 严格串行
- **终验清单**：
  - [ ] 将 `resign.json` 模拟为满 5 天，验证后台 25 分钟巡检自动完成从 `main` worktree 重签 + 无线安装 + `ExpirationDate` 后移 + 静默 Bark 回执
  - [ ] 快捷指令归家自动触发链路实测通过
  - [ ] 全部白名单配置、`depot_enabled` 开关与双指纹轮换验收完毕
  - [ ] 合并 Phase 4 代码至 `dev` → `main` 并部署，确认线上 `deploy.py --check` 全绿
