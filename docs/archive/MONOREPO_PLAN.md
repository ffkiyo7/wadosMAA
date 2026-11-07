> 归档：这是合仓前写的方案（推荐的是 A）。实际按方案 B 做的：新建仓库，两边用 subtree 方式并入，并改写了自有提交去掉 Claude 署名，所以下文里的提交号都是旧仓库的。

# Wado's MAA 合仓方案（只规划，未动手）

> 2026-11-07 21:10（北京时间）只读扫描后写成。这次没有改任何仓库、分支、软链，也没有跑 `deploy.py`（只跑了一次 `--check`）。
> 结论：**可以合，推荐方案 A**：以 maa-remote 仓库为底，先用一个纯 `git mv` 提交把它挪进 `maa-remote/`，再把 GUI 分支用 subtree 方式（不 squash）并进 `gui/`。
> 合完的仓库根就放在 `~/Developer/wados-maa`，`gui/` 和 `maa-remote/` 的路径跟现在**一字不差**，所以开发副本软链、文档里的大部分路径、Claude 的记忆目录都不用动。
> 两边所有提交的哈希都保留，以后从上游 MaaMacGui 拉更新用 `git merge -X subtree=gui`。

---

## 1. 现状

### 1.1 两个仓库

| | maa-remote | GUI（MaaMacGui fork） |
|---|---|---|
| 主仓库 | `~/Developer/personal/maa-remote`（检出 `main`） | `~/Developer/forks/MaaMacGui`（检出 `remotectrl-supported-dev-1106`） |
| 工作区 worktree | `~/Developer/wados-maa/maa-remote`（`remotectrl-supported-dev-1106`，元数据名 `maa-remote-dev`） | `~/Developer/wados-maa/gui`（`claude/redesign-ui-60930c`，元数据名 `redesign-ui-60930c`） |
| 远端 | `origin` = `github.com/ffkiyo7/maa-remote`，**公开**仓库，8 个 PR，有 Actions | 只有 `upstream` = `MaaAssistantArknights/MaaMacGui`（无 origin，没推过） |
| 提交量 | `main` 115 个（首个 2026-08-02）；`main` 比 `origin/main` 多 10 个未推；dev 分支比 `main` 多 4 个（未部署） | 上游 `master` 308 个；fork 自己 42 个（`remotectrl` 14 个 + `redesign` 再叠 28 个），线性、基于上游 `b2c99a8`（2026-11-03） |
| 分支关系 | `main`（020ed4b）= 线上已部署版本 | `remotectrl-supported-dev-1106` 是 `redesign` 的祖先，`redesign` 是唯一需要保留的 tip（a2d1436，今天 20:57 还在提交） |
| `.git` 体积 | 15 MB（pack 不到 1 MB） | 11 MB（pack 9.6 MB） |
| 跟踪文件 | 79 个 | 169 个 |
| 大文件 | 最大是 `docs/DEV_GUIDE.md` 199 KB | `ExternalTools/adb` 14.7 MB（上游自带的二进制），其余都 < 1 MB |
| LFS / submodule | 都没有 | 都没有 |
| `Vendor` / `Packages` | — | `Vendor/MaaCore`（32 KB：头文件 + `.tbd` 存根 + `PINNED_VERSION`）；`Packages/LegacyUserTasks`（本地 Swift 包）；远程 SPM 依赖只有 `JBird` |
| CI | `.github/workflows/tests.yml`：push `main` 和 PR 时在 macOS 上跑单测（3.11/3.12 × 两种 HOME）和 ruff + pyright | 无 |
| `.gitignore` | `__pycache__/`、`*.py[cod]`、`.DS_Store` | Xcode + macOS 模板、`DerivedData/`、`Local.xcconfig` 等 |
| 许可证 | MIT（`LICENSE`） | 上游仓库**没有 LICENSE 文件**（GitHub API 返回 null） |
| 其他 | `tags` 0 个 | `tags` 1 个：`v0.0.1`（上游 2022 年的旧标签） |

两棵树合起来只在根目录撞两个名字：`.gitignore`、`README.md`。放进各自子目录后就不撞了。

### 1.2 工具

- `git 2.53.0`（Homebrew）**没有 `git subtree`**；`/usr/bin/git`（Apple 自带）有。下面的步骤用不依赖 subtree 的等价命令（`merge -s ours` + `read-tree --prefix`），两种写法都给。
- `git-filter-repo 2.47.0` 已装（方案 A 用不到）。

### 1.3 线上和 cron（只读看的）

- 今天 21:00 跑了 `python3 deploy.py --check`（在 `~/Developer/personal/maa-remote`）：`ok: true`，`missing` / `mismatched` 都空，adapter `patched`。也就是**线上 = `main` 020ed4b**。两条 warning：venv 与 .venv 并存；maa-cli v0.7.5→v0.7.8、MaaCore v6.21.3→v6.21.4 跟 `verified_versions.json` 不一致。
- **cron 已不是「全部暂停」**：`MAA 计划卡·早`（03d5e98ce8d4）和 `MAA 日常·早`（50cd1fb095f2）现在是 `scheduled`，京 07:50 / 08:00 会跑；晚场、活动监控、仓库对表仍暂停。工作区 `AGENTS.md` 那句「cron 当前全部暂停」已过时。
- `run.lock` 当时为空。

---

## 2. 依赖当前路径的地方

按「合仓后要不要改」分。推荐方案把仓库根放在 `~/Developer/wados-maa`、子目录仍叫 `gui/` 和 `maa-remote/`，所以大部分**不用改**。

### 2.1 不用改（路径不变或本来就是相对路径）

| 位置 | 内容 | 为什么不用改 |
|---|---|---|
| `~/Developer/forks/maa-remote-devhome/scripts` 软链 | → `/Users/wadorudi/Developer/wados-maa/maa-remote/scripts` | 合仓后这个路径仍然存在（变成 monorepo 的子目录） |
| `maa-remote/deploy.py` | `ROOT = Path(__file__).resolve().parent`，源目录全是 `ROOT / "scripts"`、`ROOT / "config" / "maa-cli"`、`ROOT / "state"`、`ROOT / "skills"`、`ROOT / "config/verified_versions.json"`；目标是 `~/.hermes` | 随文件一起挪进 `maa-remote/`，`ROOT` 自动指向子目录 |
| `maa-remote/pyproject.toml` | ruff / pyright 的 `include`、`executionEnvironments.root` 都相对 pyproject 所在目录 | 在 `maa-remote/` 里跑 `uvx ruff` / `uvx pyright` 即可 |
| `maa-remote/tests/` | 测试按 `__file__` 加 `scripts/`、仓库根进 `sys.path`；要求「在仓库根跑」 | 改成「在 `maa-remote/` 里跑」，命令本身不变 |
| GUI 的 Xcode 工程 | `LIBRARY_SEARCH_PATHS = $(SRCROOT)/Vendor/MaaCore/lib`、`SWIFT_INCLUDE_PATHS = $(SRCROOT)/Vendor/MaaCore/include`；rpath 是 `$(HOME)/Library/Application Support/com.loong.maa/lib`；本地包 `Packages/LegacyUserTasks` 用相对路径 | 全部相对 `SRCROOT` 或绝对到 maa-cli，与仓库位置无关 |
| `gui/tools/sync-maacore.sh` | 开头 `cd "$(dirname "$0")/.."` | 相对脚本位置 |
| `gui/Version.xcconfig` | `#include? "Local.xcconfig"` | 相对；`Local.xcconfig` 目前不存在（签名配置不靠它） |
| GUI 代码 `RemoteConfig.swift` | `developmentHermesHome = "~/Developer/forks/maa-remote-devhome"`、`liveHermesHome = "~/.hermes"` | 指向运行目录，不指向仓库 |
| GUI 和 maa-remote 之间 | GUI 只经 `HERMES_HOME/scripts/maa_action.py` 和 `HERMES_HOME/state/maa/` 打交道（DEV_GUIDE §12），GUI 代码里没有 `../maa-remote` 之类的相对引用 | 接口不变 |
| `~/.hermes` 下的 cron、技能、记忆、config | `jobs.json` 里 MAA 的 cron 只按文件名跑 `~/.hermes/scripts/*.py`，workdir 是 `~/.hermes/state/maa/{am,pm}`；技能和记忆里没有仓库路径 | 线上只认部署后的副本 |
| `~/.hermes/scripts/maa_farming.py` | `USER_AGENT = "maa-remote/4 (+https://github.com/ffkiyo7/maa-remote)"` | 只是 UA 字符串；就算以后 GitHub 仓库改名也会自动跳转 |
| Claude 记忆目录 | `~/.claude/projects/-Users-wadorudi-Developer-wados-maa/` 按路径命名 | 根路径不变 |
| 构建输出 | `~/Developer/forks/wados-maa-build/`（4.6 GB，在仓库外） | 继续放仓库外，只是 `-project` 参数前面多 `gui/` |

### 2.2 要改

| 位置 | 现在 | 改成 |
|---|---|---|
| `.github/workflows/tests.yml` | 在仓库根跑 | 文件留在 monorepo 根的 `.github/`（GitHub 只认根目录）；加 `defaults.run.working-directory: maa-remote`；`on.push.paths` / `pull_request.paths` 限定 `maa-remote/**` 和该 workflow 本身 |
| 部署的源目录 | 在 `~/Developer/personal/maa-remote`（`main`）里跑 `python3 deploy.py` | 新的部署 worktree `~/Developer/wados-maa-deploy`（`main`）里跑 `python3 maa-remote/deploy.py`（推荐，见 §4）|
| 工作区 `AGENTS.md` | 两个 worktree 的表、`git -C <子目录>` 分开提交、部署第 2–3 步的路径、「cron 当前全部暂停」 | 一个仓库、一个分支；部署步骤换成新路径；cron 现状更正 |
| `maa-remote/AGENTS.md` | 「要在仓库根目录跑」「仓库不是运行目录」 | 「在 `maa-remote/` 里跑」 |
| `maa-remote/docs/DEV_GUIDE.md` | §12 第一行 `~/Developer/forks/MaaMacGui 的 fork`；§7、§9 的命令默认在仓库根 | 改成 `gui/`；命令前注明在 `maa-remote/` 里跑；CI 一节说明 working-directory |
| `gui/docs/SESSION_BRIEF.md`、`gui/docs/PLAN_MACGUI.md` | 主仓库表、`~/Developer/forks/MaaMacGui`、`~/Developer/personal/maa-remote`（HANDOFF 已记成待修） | 改成单仓库的说法；构建命令 `-project gui/MeoAsstMac.xcodeproj` |
| `HANDOFF.md` | 第 2 条「要不要 push」按两个仓库说 | 下一次交接时按单仓库写 |
| 新增根 `.gitignore` | — | `.DS_Store`、`.claude/worktrees/`（App 开 worktree 会话时会建在这里）、`.ruff_cache/` |

### 2.3 和合仓无关、但扫到了的

- `~/.hermes/scripts/doc_drift_patrol.py`（cron「三仓库文档漂移巡检」，已暂停）里的 `REPOS` 还写着 `/Users/wadorudi/Desktop/dev/maa-remote`，这个路径早就不对了。合仓后如果要恢复这条 cron，要改成 `~/Developer/wados-maa`。它不归 maa-remote 管，不在本方案范围内。
- 工作区 `AGENTS.md` 的「cron 当前全部暂停」已过时（见 1.3）。

---

## 3. 方案对比

| | A. maa-remote 为底 + `git mv` + GUI subtree 并入（**推荐**） | B. 新建空仓库，两边都 subtree 并入 | C. `filter-repo` 把两边历史改写进子目录再拼起来 | D. GUI 为底（Xcode 留在根）+ maa-remote subtree 并入 | E. GUI squash 并入 | F. 保持两仓库，只加一个顶层 meta 仓库 |
|---|---|---|---|---|---|---|
| 历史保留 | 全部保留 | 全部保留 | 全部保留，但内容被改写 | 全部保留 | GUI 的 42 个提交压成 1 个 | 不涉及 |
| 提交哈希 | **两边都不变**（DEV_GUIDE / HANDOFF 里引用的 `49da169`、`020ed4b`、GitHub PR 链接都还有效） | 两边都不变 | **全部变** | 两边都不变 | maa-remote 不变；GUI 丢失 | 不变 |
| 单文件 `git log` | maa-remote：`git log --follow` 跨过挪目录那一步；GUI：子树并入前的历史要在旧路径上看（`git log a2d1436 -- MeoAsstMac/…`） | 两边都要在旧路径看 | 最连续，`git log gui/…` 直接看到底 | GUI 最连续；maa-remote 要在旧路径看 | — | 不变 |
| 从上游 MaaMacGui 拉更新 | `git merge -X subtree=gui upstream-gui/master`（或 `/usr/bin/git subtree merge --prefix=gui`），合并基是真的 `b2c99a8` | 同 A | **坏掉**：改写后的上游提交和真上游不同哈希，找不到合并基，只能手搬补丁 | 最简单，直接 `git merge upstream/master` | 每次都要 `subtree merge --squash`，冲突更难查 | 不变（在 fork 里 `git merge upstream/master`） |
| 部署流程 | 换个目录：部署 worktree 里跑 `python3 maa-remote/deploy.py` | 同 A | 同 A | 同 A | 同 A | 不变 |
| GitHub | 可以直接推到现有 `ffkiyo7/maa-remote`（PR、Actions 都接得上），或者改名 | 要新仓库 | 只能新仓库或强推覆盖 | maa-remote 的 `.github/` 要挪到根，旧仓库接不上 | 同 A | 不变 |
| 路径改动 | `gui/`、`maa-remote/` 路径不变 | 同 A | 同 A | GUI 文件到了根上，工作区 `gui/` 路径全变；根目录被 Xcode 文件占满 | 同 A | 不变 |
| 风险 | 低。所有原始对象原样保留，旧仓库一个字节都不改 | 低 | 中高（哈希全变、上游断） | 中（文档、构建命令里的 `gui/` 都要改） | 低，但损失大 | 最低 |
| 回滚 | 两个旧仓库原封不动，挪回 worktree 即可（§4.6） | 同 A | 同 A | 同 A | 同 A | 删掉 meta 仓库 |
| 工作量（估） | 3–4 小时（构建 1 h、验证 1.5 h、切换 0.5 h、改文档 1 h） | 同 A | 4–6 小时，且以后每次拉上游都要额外处理 | 4–5 小时 | 2–3 小时 | 0.5 小时 |
| 解决的问题 | 一个仓库一个分支；改 §12 接口时 GUI 和 maa-remote 能在**同一个提交**里改、一起验证 | 同 A | 同 A | 同 A | 同 A | 只解决「顶层文档没人管」，不能原子提交 |

**为什么选 A 不选 D**：D 拉上游最省事，但 fork 已经大改（重设计 28 个提交），以后拉上游本来就要手解冲突，多一个 `-X subtree=gui` 不算成本；而 D 要把 maa-remote 的 CI 和 GitHub 历史接到一个新根上，路径也全变。maa-remote 是天天在部署的那个，以它为底最稳。

**为什么不选 C**：一改写哈希，文档里写的提交号、GitHub PR 里的提交链接全失效；更要命的是上游 MaaMacGui 的那 308 个提交也被改写了，以后 `merge upstream` 找不到合并基。

---

## 4. 推荐方案 A 的分步迁移

### 4.0 合完的样子

```
~/Developer/wados-maa/            ← monorepo 主检出，平时在 dev 分支
├── .github/workflows/tests.yml   ← 从 maa-remote 根挪上来，working-directory: maa-remote
├── .gitignore                    ← 新：.DS_Store、.claude/worktrees/、.ruff_cache/
├── AGENTS.md  CLAUDE.md          ← 工作区现有的两份，改写后入库
├── HANDOFF.md  MONOREPO_PLAN.md  ← 是否入库见 §5 问题 6
├── README.md                     ← 新，三五行：两个子目录各是什么
├── gui/                          ← MaaMacGui fork（含它自己的 .gitignore、README）
└── maa-remote/                   ← 原仓库根的全部内容（LICENSE、deploy.py、scripts/…）

~/Developer/wados-maa-deploy/     ← 同一仓库的 worktree，固定在 main，只用来部署
```

分支：

- `main`：线上部署的版本。规则不变——**`main` = 已部署**，`deploy.py --check` 在它上面必须 `ok`。
- `dev`：日常开发，GUI 和 maa-remote 都在这上面提交（取代现在的 `remotectrl-supported-dev-1106` 和 `claude/redesign-ui-60930c` 两个分支）。
- 远端：`old-maa-remote`（指向本地 `~/Developer/personal/maa-remote`，只读备查）、`upstream-gui`（官方 MaaMacGui，只拉 `master`、不拉标签）；GitHub 远端看 §5 问题 3。

### 4.1 预检（只读，开工当天做）

1. 所有关联会话都空闲，两个 worktree `git status` 干净、没有 stash。GUI 今天 20:57 还在提交，要等它停下。
2. 记下各 tip：maa-remote `main`（今天是 020ed4b）、dev（603d163）；GUI `claude/redesign-ui-60930c`（今天是 a2d1436）、上游 `master`（b2c99a8）。
3. 时间避开早场：`计划卡·早` 07:50、`日常·早` 08:00 正在启用，**京 07:20–08:40 不做第 4.4 步**；晚场现在暂停，如果到时恢复了，也避开 21:20–22:40。
4. `~/.hermes/state/maa/run.lock` 为空。
5. 在 `~/Developer/personal/maa-remote` 跑 `python3 deploy.py --check`，`ok: true` 作为基线。

### 4.2 在暂存目录里拼仓库（不碰任何现有东西）

```bash
S=~/Developer/wados-maa-staging
git clone --no-local ~/Developer/personal/maa-remote "$S"
cd "$S"
git remote rename origin old-maa-remote
```

**第 1 个提交：只挪目录，不改内容**（这样 rename 识别是 100%，`--follow` 最稳）：

```bash
mkdir maa-remote
git ls-tree --name-only HEAD | grep -vxE '\.github|maa-remote' | xargs -I{} git mv {} maa-remote/
git commit -m "refactor: maa-remote 整体挪进 maa-remote/ 子目录，为和 GUI 合仓做准备" -m "…"
```

`.github/` 留在根（GitHub 只认根目录）。

**第 2 个提交：CI 改到子目录**：`tests.yml` 加 `defaults.run.working-directory: maa-remote` 和 `paths` 过滤；跑一次 `actionlint`（可选）。

**第 3 个提交：并入 GUI，保留原哈希**：

```bash
git remote add gui-fork ~/Developer/forks/MaaMacGui
git fetch --no-tags gui-fork claude/redesign-ui-60930c
git merge -s ours --no-commit --allow-unrelated-histories gui-fork/claude/redesign-ui-60930c
git read-tree --prefix=gui/ -u gui-fork/claude/redesign-ui-60930c
git commit -m "feat: Wado's MAA 界面并进 gui/，保留 fork 的全部提交历史"
# 等价写法：/usr/bin/git subtree add --prefix=gui gui-fork claude/redesign-ui-60930c
```

**第 4 个提交：根文件和文档**：根 `.gitignore`、`README.md`；工作区 `AGENTS.md` / `CLAUDE.md`（改写，见 §2.2）；`maa-remote/AGENTS.md`、DEV_GUIDE §7/§9/§12、`gui/docs/SESSION_BRIEF.md`、`PLAN_MACGUI.md` 的路径。

**建 `dev`，带上 maa-remote 未部署的 4 个提交**：

```bash
git switch -c dev
git merge old-maa-remote/remotectrl-supported-dev-1106
# merge-ort 按目录改名把这 4 个提交的改动落到 maa-remote/ 下
git ls-tree --name-only HEAD   # 根目录只能有：.github .gitignore AGENTS.md CLAUDE.md README.md gui maa-remote（+ 问题 6 决定入库的文档）
```

**上游远端**：

```bash
git remote add upstream-gui https://github.com/MaaAssistantArknights/MaaMacGui.git
git config remote.upstream-gui.fetch '+refs/heads/master:refs/remotes/upstream-gui/master'
git config remote.upstream-gui.tagOpt --no-tags
git remote remove gui-fork   # 对象已经进来了
```

### 4.3 在暂存目录里验证

| 验什么 | 怎么验 | 通过标准 |
|---|---|---|
| 历史都在 | `git merge-base --is-ancestor <哈希> dev`，依次查 020ed4b、603d163、a2d1436、b2c99a8 | 四个都是祖先 |
| GUI 内容一字不差 | 第 3 个提交上 `git rev-parse <提交>:gui` 对比 `git -C ~/Developer/forks/MaaMacGui rev-parse a2d1436^{tree}`（今天是 `22fbc245…`） | 树哈希相同 |
| maa-remote 内容一字不差 | `diff <(git ls-tree -r main~N:maa-remote) <(git -C ~/Developer/personal/maa-remote ls-tree -r 020ed4b \| grep -v '\.github/')`（N 取到第 1 个提交） | 无差异 |
| 改名历史 | `git log --follow --oneline maa-remote/scripts/maa_daily.py \| wc -l` | 跟旧仓库 `git log --oneline scripts/maa_daily.py` 条数一样 |
| 单测 | 在 `$S/maa-remote` 里：`python3 -m unittest discover -s tests`；`HOME="$(mktemp -d)" python3 -m unittest discover -s tests`；`env -u PYTHONDONTWRITEBYTECODE /usr/bin/python3 -m unittest discover -s tests`；`uvx ruff@0.17.3 check`；`uvx pyright@1.1.414` | 全绿、0 报错，用例数跟旧 worktree 一致 |
| 部署源目录 | `git switch main` 后在 `$S/maa-remote` 跑 `python3 deploy.py --check` | `ok: true`、`mismatched` 空——证明新位置的 `ROOT` 认得对，**这是部署路径改动的关键验证** |
| GUI 构建 | `xcodebuild -project gui/MeoAsstMac.xcodeproj -scheme MAA -configuration Release -derivedDataPath ~/Developer/forks/wados-maa-build/mono -skipMacroValidation -skipPackagePluginValidation build` | BUILD SUCCEEDED |
| 上游合并机制 | `git fetch upstream-gui`；`git merge-base dev upstream-gui/master` | 等于 b2c99a8（或上游新提交的祖先）。若上游已有新提交，在一次性分支上 `git merge --no-commit -X subtree=gui upstream-gui/master` 看改动是不是都落在 `gui/` 下，然后 `git merge --abort` |
| `blame` 能不能跨过子树并入 | `git blame gui/MeoAsstMac/Remote/RemoteStore.swift \| head` | 能看到 fork 原来的提交号就算过；看不到也不阻塞，记进文档（以后在旧路径上看） |

这一步任何一项不过，直接删掉 `$S` 重来，现有环境没有任何变化。

### 4.4 切换（约 10 分钟，App 退出、避开早场）

1. 退出 Wado's MAA；确认 `run.lock` 空；确认没有会话在两个 worktree 里干活。
2. 把旧 worktree 挪走（只改旧仓库的 worktree 元数据，可逆）：

   ```bash
   mkdir -p ~/Developer/forks/_retired
   git -C ~/Developer/forks/MaaMacGui worktree move ~/Developer/wados-maa/gui ~/Developer/forks/_retired/gui-redesign
   git -C ~/Developer/personal/maa-remote worktree move ~/Developer/wados-maa/maa-remote ~/Developer/forks/_retired/maa-remote-dev
   ```

   从这里到第 4 步之前，开发副本的 `scripts` 软链是断的（线上 `~/.hermes` 不受影响）。
3. 换掉工作区目录：工作区剩下的 `AGENTS.md` / `CLAUDE.md` / `HANDOFF.md` / `MONOREPO_PLAN.md` 在 4.2 已经拷进仓库了。

   ```bash
   mv ~/Developer/wados-maa ~/Developer/forks/_retired/wados-maa-workspace
   mv ~/Developer/wados-maa-staging ~/Developer/wados-maa
   git -C ~/Developer/wados-maa switch dev
   ```

4. 建部署 worktree（**必须在 mv 之后建**，worktree 记的是绝对路径）：

   ```bash
   git -C ~/Developer/wados-maa worktree add ~/Developer/wados-maa-deploy main
   ```

5. 验证：
   - `readlink ~/Developer/forks/maa-remote-devhome/scripts` 仍是 `/Users/wadorudi/Developer/wados-maa/maa-remote/scripts`，且 `ls` 能列出脚本；
   - `HERMES_HOME=~/Developer/forks/maa-remote-devhome python3 ~/Developer/forks/maa-remote-devhome/scripts/maa_action.py run choices` 返回 `ok: true`（只读命令）；
   - `cd ~/Developer/wados-maa-deploy/maa-remote && python3 deploy.py --check` → `ok: true`；
   - 用 4.3 构建出来的 App（`~/Developer/forks/wados-maa-build/mono/…/Wado's MAA.app`）打开，首页能读到锁和最近一场。

### 4.5 切换后的日常流程

- 开发：在 `~/Developer/wados-maa` 的 `dev` 上改，GUI 和 maa-remote 可以同一个提交（改 §12 接口时必须同一个提交）。
- 测试：`cd ~/Developer/wados-maa/maa-remote && python3 -m unittest discover -s tests`（ruff / pyright 同目录）。
- 部署（取代 AGENTS.md 现在的第 2–3 步）：

  ```bash
  git -C ~/Developer/wados-maa-deploy merge --ff-only dev
  cd ~/Developer/wados-maa-deploy/maa-remote && python3 deploy.py && python3 deploy.py --check
  ```

  `main` 上会带着 GUI 的改动，这不影响部署：`deploy.py` 只读 `maa-remote/` 下的东西。
- 拉上游 MaaMacGui：

  ```bash
  git fetch upstream-gui
  git switch -c sync/upstream-YYYYMMDD dev
  git merge -X subtree=gui upstream-gui/master     # 或 /usr/bin/git subtree merge --prefix=gui upstream-gui/master
  # 解冲突 → xcodebuild → 合回 dev
  ```

  给上游提 PR（如果以后需要）：`/usr/bin/git subtree split --prefix=gui -b gui-only`，得到一条以 `gui/` 为根的分支。
- 看 GUI 合仓前的历史：`git log a2d1436 -- MeoAsstMac/Remote`（旧路径）。

### 4.6 回滚

| 到了哪一步 | 怎么回 |
|---|---|
| 4.2 / 4.3 | 删掉 `~/Developer/wados-maa-staging`，什么都没变 |
| 4.4 之后、还没在新仓库提交 | 退出 App；`git -C ~/Developer/wados-maa worktree remove ~/Developer/wados-maa-deploy`；`mv ~/Developer/wados-maa ~/Developer/wados-maa-mono`；`mv ~/Developer/forks/_retired/wados-maa-workspace ~/Developer/wados-maa`；两条 `git worktree move` 反着各跑一次挪回 `~/Developer/wados-maa/{gui,maa-remote}`。软链路径没变，自动恢复 |
| 新仓库里已经有提交 | 同上，再把新提交搬回旧仓库：`git format-patch <合仓点>..dev -- maa-remote/` 后在旧 maa-remote 里 `git am -p2`；GUI 的同理（`-- gui/`，`-p2`）|
| 已经从新路径部署过 | 线上回滚跟以前一样：`deploy.py` 自己的备份在 `~/.hermes/backups/maa-setup/<时间>/`；旧仓库 `~/Developer/personal/maa-remote` 的 `main` 还能直接 `python3 deploy.py` |

旧仓库 `~/Developer/personal/maa-remote`、`~/Developer/forks/MaaMacGui` 在整个过程中**内容一个字节不改**（只是 worktree 元数据被 `worktree move` 改了路径）。建议保留至少一个月，确认没问题再删（问题 7）。

### 4.7 要注意的

- 合仓前所有在跑的会话都要停，否则会有人往已经挪走的 worktree 里提交。合仓后，旧会话（cwd 在 `~/Developer/wados-maa/gui` 或 `/maa-remote`）的路径仍然存在，但已经是 monorepo 的子目录，分支也变成 `dev`；最好都开新会话。
- `~/Developer/wados-maa/MONOREPO_PLAN.md` 本身在工作区里，4.2 要记得拷进去（或按问题 6 的决定不入库）。
- **我没有在暂存目录里实际试拼一次**（任务限定只写这一个文件）。§4.2 的命令是按 git 2.53 的行为写的，`-X subtree=gui` 合并和目录改名合并都是 git 的标准能力，但第一次真跑时以 4.3 的验证为准。

---

## 5. 需要你决定的问题

1. **用哪个方案？**
   推荐 **A**（maa-remote 为底，GUI subtree 并入，哈希全保留）。只想先理顺文档、不想动 git 的话选 F。

2. **合完的仓库根放哪？**
   推荐 **就放 `~/Developer/wados-maa`**：`gui/`、`maa-remote/`、开发副本软链、记忆目录全都不用动。另一个选择是新路径（比如 `~/Developer/personal/wados-maa`），那软链和所有文档路径都要改。

3. **GitHub 远端怎么办？**（现在 `ffkiyo7/maa-remote` 是**公开**的，GUI 从没推过）
   推荐 **先不设远端，本地跑一两周再说**——现在两边本来就都有一堆没推的提交。以后要推时二选一：
   - 推到现有 `ffkiyo7/maa-remote` 并改名为 `wados-maa`：PR、Actions、公开仓库的免费 macOS 分钟都接得上，旧链接自动跳转；代价是 GUI 代码（含上游 14.7 MB 的 `adb` 二进制）也公开，且上游 MaaMacGui 没有 LICENSE 文件，公开 fork 的授权要你自己判断；
   - 新建私有仓库 `ffkiyo7/wados-maa`：不公开，但私有仓库的 macOS runner 按 10 倍计分钟，现在这套 CI（3 个 job）推几次就可能吃掉免费额度，可能要关 CI 或只在 PR 上跑。

4. **分支怎么排？**
   推荐 **主检出在 `dev`，另开 `~/Developer/wados-maa-deploy` 固定在 `main` 只做部署**，跟现在「worktree 开发、主仓库 main 部署」一模一样。更简单的做法是只有 `main`、直接在主检出里部署，但那样「`main` = 已部署」就守不住了。

5. **哪些分支要带进来？**
   推荐：
   - maa-remote：`main` + dev 的 4 个未部署提交（进 `dev`）；
   - GUI：只带 `claude/redesign-ui-60930c`（`remotectrl-supported-dev-1106` 是它的祖先，自动包含）；
   - GitHub 上 maa-remote 的旧分支（`playcover`、`claude/project-thread-ygiqxv`）和本地那 7 个早已合并的远端跟踪分支**不带**，留在旧仓库里；
   - 上游的 `v0.0.1` 标签不带。

6. **工作区的几份文档入不入库？**
   推荐：`AGENTS.md`、`CLAUDE.md` **入库**（改写成单仓库的说法）；`HANDOFF.md` **入库**（交接说明跟代码一起走，以后的会话都能看到历史）；`MONOREPO_PLAN.md` 合完后挪进 `docs/` 或直接删掉，你定，我推荐挪进 `docs/archive/`。

7. **旧仓库怎么处理？**
   推荐 **保留一个月不动**（`~/Developer/personal/maa-remote`、`~/Developer/forks/MaaMacGui`、`~/Developer/forks/_retired/`），作为回滚和部署后备；一个月后确认没问题再删。

8. **提交标题要不要带范围？**
   现在 maa-remote 的规范是 `<type>: <中文>`。合仓后一个提交可能只动一边，推荐 **加可选范围**：`feat(gui): …`、`fix(remote): …`，两边都动就不写范围。这要改 `maa-remote/AGENTS.md` 的提交规范。

9. **CI 要不要加 GUI 构建？**
   推荐 **先不加**：GitHub 的 macOS runner 不一定有 Xcode 26.6 / macOS 26 SDK，而且 App 只在本机构建自用；等问题 3 定了远端再说。

10. **什么时候做？**
    要一段整块时间（3–4 小时，其中切换 10 分钟需要 App 退出、所有会话停下）。推荐 **找一个白天、早场 08:00 跑完之后**做，比如 09:00–13:00（北京时间）。
