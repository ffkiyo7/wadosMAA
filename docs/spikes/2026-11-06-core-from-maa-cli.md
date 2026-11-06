# S0a spike：fork 不带 MaaCore，直接用 maa-cli 装的 Core 和资源

> 2026-11-06 12:05–12:30（北京时间）。只验证可行性，不含产品代码。
> 现场：MaaMacGui `b2c99a8`（分支 `remotectrl-supported-dev-1106`），macOS 26.6，Xcode 26.6（17F113）。
> 所有改动都在隔离副本里做：`/private/tmp/claude-501/-Users-wadorudi-Developer-personal-maa-remote/bd415c7a-9441-40b0-8724-226c389bc077/scratchpad/spike-core`（下文简称 `$S/spike-core`，`$S` 为 scratchpad 根目录）。fork 仓库只多了本文件，没有提交、没有推送。
> 遵守的约束：没有启动或连接游戏、PlayCover、MaaTools；没有跑任何 maa 任务或更新命令，只跑了 `maa version`；`com.loong.maa`、`~/.config/maa-cli`、`~/Library/Caches/com.loong.maa` 全程只读。所有运行结束后用 `find -newer <标记文件>` 核对过，这三个目录下没有新写入的文件。`AsstSetUserDir` 一律指向 `$S/userdir/*`。

## 0. 结论

**有条件可行。** fork 可以用 `xcodebuild` 编过，链接 maa-cli 的 `libMaaCore.dylib`。运行时 dyld 从 `~/Library/Application Support/com.loong.maa/lib` 加载全部 5 个 dylib，依次加载 maa-cli 的四层资源都成功，`AsstGetVersion()` 返回 `v6.21.4`。没有缺符号，也没有发现 ABI 不匹配。

条件有四条：

1. **库验证**：开着硬化运行时（hardened runtime），就必须带 `com.apple.security.cs.disable-library-validation`，否则 dyld 拒绝加载。原因是 maa-cli 的 dylib 只有链接器打的 ad-hoc 签名，没有 Team ID。另一个办法是关掉硬化运行时（K8 不做公证，可以不开）。
2. **沙盒**：开着沙盒时，dylib 照样能加载，但 `AsstLoadResource` 读不到 maa-cli 的资源，全部失败。按 K8 去掉沙盒就行。另一种做法也实测可行：保留沙盒，加 `temporary-exception` 只读例外。
3. **路径**：GUI 里所有指向 App 包内 `resource/` 的路径都要改到 maa-cli 的目录。现在的代码在没有包内资源时，`initialize()` 第一步就会抛错（见 §8）。
4. **版本漂移**：Core 只有一份，maa-cli 一换 Core，GUI 下次启动就跟着换。`AsstCallerExtra.h` 明确写着是实验接口，不保证兼容。所以要有启动预检和版本核对（见 §7、§8）。

**推荐方案**：用 module.modulemap 包头文件，再配一个 `.tbd` 文本存根做**弱链接**；rpath 指向 `$(HOME)/Library/Application Support/com.loong.maa/lib`。不往 App 包里拷 dylib。理由见 §6。

---

## 1. 版本信息

| 项 | 值 | 怎么查的 |
|---|---|---|
| maa-cli | v0.7.5 | `maa version` |
| maa-cli 的 MaaCore | **v6.21.4**（Beta 通道），`Built at Nov 4 2026 09:51:06` | `maa version`；运行时 `AsstGetVersion()`；`asst.log` |
| 对应 tag | `v6.21.4`，tag 对象 `526df711…`，commit `52d0b2acaca116585b02e1e6a9da303460f81a24`，打 tag 时间 2026-11-04T09:48:42Z | `gh api …/git/ref/tags/v6.21.4` |
| 官方 MAA.app（`~/.Trash/MAA.app`，只读） | Info.plist 里是 **v6.21.4（build 1031）**，不是任务描述里的 v6.21.0-beta.3。Info.plist 和 dylib 的 mtime 都是 11-06 11:44，可能扔进废纸篓前被 Sparkle 更新过 | `PlistBuddy`；`strings` |
| 两份 dylib 是否同一次构建 | **是**。5 个 dylib 的 arm64 和 x86_64 的 LC_UUID 两两相同。抽查了 libMaaCore 和 libonnxruntime 的 arm64 切片：去掉签名后整个文件只差 1–2 个字节，在 load command 区 | `dwarfdump --uuid`；`codesign --remove-signature` 后 `cmp -l` |
| 第三方版本 | OpenCV 4.12.0（`libopencv_world4.4.12.0.dylib`）、ONNX Runtime 1.19.2 | `otool -L` |
| 架构 / 最低系统 | 全部是 universal（x86_64 + arm64）；MaaCore 和 MaaUtils 的 minos 是 13.3，其余是 11.0 | `lipo`、`otool -l` |
| 签名差异 | maa-cli：`flags=0x20002(adhoc,linker-signed)`，`TeamIdentifier=not set`。官方 App：`flags=0x10000(runtime)`，Team `29V29Y67P2` | `codesign -dv` |
| install name / rpath | 都是 `@rpath/libXxx.dylib`。libMaaCore 自带 `LC_RPATH @loader_path/`，所以只要 App 找到 libMaaCore，它的依赖会自动从同目录加载 | `otool -l` |
| xattr | maa-cli 的 dylib 只有 `com.apple.provenance`，没有 `com.apple.quarantine` | `xattr` |

maa-cli 的 `lib/` 里还多一个 `libMaaAdbControlUnit.dylib`，官方 App 没带。Core 只在走 MaaFramework 的 ADB 控制器时才 `dlopen` 它，PlayTools 路线用不上（见 §7.9）。

## 2. 符号对照表

先用 `grep -rhoE '\bAsst[A-Za-z_]+'` 列出 Swift 代码用到的 `Asst*`。函数只在 `MeoAsstMac/Core/Maa.swift` 里调；类型 `AsstMsgId` 另外在 `MaaMessage.swift` 里用到。下表的 `T` 表示 `nm -gU` 里是已导出的代码符号，每格依次是 arm64 和 x86_64 两个切片。

| 函数 | 声明所在头文件 | maa-cli 的 libMaaCore | 官方 App 的 libMaaCore | Swift 调用处 |
|---|---|---|---|---|
| `AsstSetUserDir` | AsstCaller.h | T T | T T | `MAAProvider.setUserDirectory` |
| `AsstLoadResource` | AsstCaller.h | T T | T T | `MAAProvider.loadResource` |
| `AsstCreateEx` | AsstCaller.h | T T | T T | `MAAHandle.init` |
| `AsstDestroy` | AsstCaller.h | T T | T T | `MAAHandle.deinit` |
| `AsstSetInstanceOption` | AsstCaller.h | T T | T T | `MAAHandle.apply(options:)` |
| `AsstAppendTask` | AsstCaller.h | T T | T T | `appendTask` |
| `AsstStart` / `AsstStop` | AsstCaller.h | T T | T T | `start` / `stop` |
| `AsstRunning` / `AsstConnected` | AsstCaller.h | T T | T T | `running` / `connected` |
| `AsstAsyncConnect` | AsstCaller.h | T T | T T | `connect` |
| `AsstGetImage` / `AsstGetNullSize` | AsstCaller.h | T T | T T | `getImage` |
| `AsstGetMapLevelKey` | **AsstCallerExtra.h**（实验接口） | T T | T T | `MAAProvider.mapLevelCode` |
| `AsstGetItemName` | **AsstCallerExtra.h**（实验接口） | T T | T T | `MAAProvider.itemName` |
| `AsstGetVersion` | AsstCaller.h | T T | T T | 现在没用到；spike 钩子和推荐的版本核对要用 |

用到的类型有 `AsstHandle`、`AsstBool`、`AsstSize`、`AsstId`、`AsstMsgId`、`AsstAsyncCallId`，以及 `AsstGetMapLevelKey` 按值返回的 `struct AsstMapLevelKey`，都在 v6.21.4 的头文件里。

两份 dylib 导出的 `_Asst*` 都是同样的 **28 个**，`diff` 结果为空。导出了但 GUI 没用到的有：`AsstAsyncClick`、`AsstAsyncScreencap`、`AsstBackToHome`、`AsstConnect`、`AsstCreate`、`AsstGetImageBgr`、`AsstGetTasksList`、`AsstGetUUID`、`AsstLog`、`AsstSetConnectionExtras`、`AsstSetStaticOption`、`AsstSetTaskParams`。

**ABI**：fork 现有的全部 Swift 代码用 v6.21.4 的头文件编译，0 个错误。运行时调了 `AsstGetMapLevelKey`（按值返回 4 个指针的结构体），4 个字段都是有效且内容自洽的字符串（见 §5），没有发现错位。

## 3. 头文件

- 来源：主仓库 tag `v6.21.4` 的 `include/`，用 `gh api …/contents/include/<f>?ref=v6.21.4 -H 'Accept: application/vnd.github.raw'` 取下来，放在 `$S/maacore-include/v6.21.4/include/`。
- 共 5 个文件：`AsstCaller.h`、`AsstCallerExtra.h`、`AsstPort.h`、`MaaCore.h`（伞头文件，定义 `ASST_WITH_EXTRA_CALLERS 1`）、`module.modulemap`。
- 上游自带的 modulemap 是 `module MaaCore { umbrella header "MaaCore.h"; export *; link framework "Accelerate"/"OpenCL"/"Vision"; link "c++" }`，**没有 `link "MaaCore"`**。上游靠 Xcode 链接 xcframework 来引入 libMaaCore，所以单用 modulemap 时要自己补上链接（见 §4）。
- `AsstLoadResource(path)` 的语义（`src/MaaCore/AsstCaller.cpp@v6.21.4`）：实际加载的是 `path/resource`；第一次调用时设置 `ResDir`；`UserDir` 为空时会被设成 `path`，所以 `AsstSetUserDir` 必须先调。因此任务描述里的 `AsstLoadResource(com.loong.maa/resource)`，实际要传 `com.loong.maa`。这和 GUI 现有写法（传 `Bundle.main.resourceURL`）以及 maa-cli 的写法（`load_resource(resource_dir.parent())`）一致。

## 4. 编译与链接：试验矩阵

### 4.1 副本里的公共改动

由 `$S/tools/patch_pbxproj.py` 生成，这样每个变体都能从原始 pbxproj 重新生成。

- `MACOSX_DEPLOYMENT_TARGET` 从 14.0 改为 26.0（project 级的 Debug 和 Release）。
- Resources 阶段去掉 `resource` 文件夹引用（`../../../../resource`，主仓库的资源）。
- target：bundle id 改为 `com.hguandl.MeoAsstMac.spikecore`，避免碰官方容器和偏好设置；`CODE_SIGN_ENTITLEMENTS` 改为 `MeoAsstMac/Spike.entitlements`，只有 DLV，没有沙盒；Release 的 `CODE_SIGN_IDENTITY` 改为 `-`，`DEVELOPMENT_TEAM` 和描述文件清空。
- 去掉 OpenCV、ONNXRuntime、fastdeploy_ppocr、MaaUtils 四个 xcframework 的链接和嵌入。Swift 只直接调 MaaCore，依赖靠 MaaCore 自带的 `@loader_path/` 去找。
- `MeoAsstMacApp.init()` 第一行加调试钩子 `SpikeCoreCheck.runIfRequested()`，代码在 `Maa.swift`。只有设置了环境变量 `MAA_SPIKE_USER_DIR` 时才跑，跑完直接 `exit`，不进 SwiftUI，也不创建 `MAAViewModel`。
- 构建命令（都在 scratch 里）：
  `xcodebuild -project MeoAsstMac.xcodeproj -scheme MAA -configuration Release -derivedDataPath $S/ddX -clonedSourcePackagesDirPath $S/spm -destination 'platform=macOS,arch=arm64' -skipMacroValidation CODE_SIGN_IDENTITY=- build`

### 4.2 两个维度

| 变体 | 怎么链接 | 运行时怎么找库 | 构建 | App 大小 | dyld 实际加载位置 | 钩子结果 |
|---|---|---|---|---|---|---|
| B-rpath（Debug 和 Release） | 用 maa-cli 的 dylib 和 v6.21.4 头文件打一个 xcframework（`xcodebuild -create-xcframework -library … -headers …`），工程里的 `MaaCore.xcframework` 改指向它，只链接、不嵌入 | rpath `$(HOME)/Library/Application Support/com.loong.maa/lib` | 成功 | 34 MB | `com.loong.maa/lib` 下全部 5 个 | ALL OK |
| A-rpath | `include/`（头文件 + 带 `link "MaaCore"` 的 modulemap）+ `lib/libMaaCore.tbd`；`SWIFT_INCLUDE_PATHS` 和 `LIBRARY_SEARCH_PATHS` 分别指向这两个目录 | 同上 | 成功 | 34 MB | 同上 | ALL OK |
| **A-weak-rpath（推荐）** | 同 A，但 modulemap 里不写 `link`，改用 `OTHER_LDFLAGS = -weak-lMaaCore`，生成的是 `LC_LOAD_WEAK_DYLIB` | 同上 | 成功 | 34 MB | 同上 | ALL OK（x86_64 在 Rosetta 下也 ALL OK） |
| B-embed | 5 个 xcframework 都用 maa-cli 的 dylib 重做，沿用上游的嵌入设置（CodeSignOnCopy） | `@executable_path/../Frameworks`，也就是拷进 App 包 | 成功 | **123 MB** | `MAA.app/Contents/Frameworks/` 下全部 5 个 | ALL OK |

`.tbd` 存根是手写的 TAPI v4 YAML，只列 28 个 `_Asst*`：`install-name: '@rpath/libMaaCore.dylib'`，`current-version: 0`，`compatibility-version: 0`，`targets: [x86_64-macos, arm64-macos]`。也可以用 `xcrun tapi stubify` 生成完整存根，但那份有 333 KB，还导出了 C++ 内部符号，不推荐。

pbxproj 里路径含空格的 rpath 要写成这样，已实测生效：
```
LD_RUNPATH_SEARCH_PATHS = (
    "$(inherited)",
    "@executable_path/../Frameworks",
    "\"$(HOME)/Library/Application Support/com.loong.maa/lib\"",
);
```
产物里 `otool -l` 显示 `LC_RPATH /Users/wadorudi/Library/Application Support/com.loong.maa/lib`。

## 5. 运行时检查

做法：编出的 `MAA.app/Contents/MacOS/MAA` 直接带环境变量运行，`MAA_SPIKE_USER_DIR=$S/userdir/<变体>`。资源按 maa-cli v0.7.5 的实际加载顺序来（源码 `crates/maa-cli/src/config/asst.rs` 里的 `default_resource_base_dirs` / `resource_dirs`）。

| # | 调用 | 加载的目录 | 结果（Release，A-weak-rpath） |
|---|---|---|---|
| 1 | `AsstSetUserDir($S/userdir/A-weak)` | — | OK |
| 2 | `AsstLoadResource(~/Library/Application Support/com.loong.maa)` | 基础资源 `…/com.loong.maa/resource` | OK，0.15 s |
| 3 | `AsstLoadResource(…/com.loong.maa/MaaResource)` | git 覆盖层 `MaaResource/resource` | OK，0.05 s |
| 4 | `AsstLoadResource(~/Library/Caches/com.loong.maa)` | maa-cli 的热更新缓存 `Caches/com.loong.maa/resource`。任务没要求，但 maa-cli 实际会加载这一层 | OK，0.03 s |
| 5 | `AsstLoadResource(~/.config/maa-cli)` | 用户资源层 `~/.config/maa-cli/resource`（`profiles/default.toml` 里 `user_resource = true`） | OK，0.03 s |
| 6 | `AsstLoadResource(…/com.loong.maa/resource/platform_diff/iOS)` | 基础资源里的 iOS 平台差异。任务没要求，maa-cli 在 PlayTools 下会加载 | OK，0.03 s |
| 7 | `AsstLoadResource(~/Library/Caches/com.loong.maa/resource/platform_diff/iOS)` | 热更新里的 iOS 平台差异，同上 | OK，0.03 s |
| 8 | `AsstGetVersion()` | — | **`v6.21.4`** |
| 附 | `AsstGetItemName("30012")` | — | `固源岩` |
| 附 | `AsstGetMapLevelKey("1-7")` | — | `code=1-7`，`stage_id=main_01-07#f#`，`level_id=obt/main/level_main_01-07`，`name=暴君` |
| 附 | `AsstGetNullSize()` | — | `18446744073709551615`（UINT64_MAX） |
| 附 | `AsstCreateEx(nil,nil)`，然后 `AsstDestroy` | — | 拿到非空句柄，`connected=0`，`running=0`；没有连接 |

- `asst.log` 里 6 次 `ResourceLoader::load` 都是 `load ret 1`。唯一的 `ERR` 是 `inited | m_controller is not inited`，这是没连接就建句柄时的正常输出。`WRN` 有三类：干员多职业提示；可选的 BlackFlow 模型缺失；`platform_diff/iOS/resource/tasks.json` 的弃用提示，maa-cli 自己跑也一样。
- Core 写入的只有 `$S/userdir/*/debug/asst.log` 和 `cache/avatars`，maa-cli 的三个目录下没有新文件。
- `_dyld_get_image_name` 显示加载的是 `…/com.loong.maa/lib/` 下的 libMaaCore、libMaaUtils、libopencv_world4.4.12.0、libfastdeploy_ppocr、libonnxruntime.1.19.2。

### 5.1 签名、沙盒与链接方式

签名变体都是在 Release 产物的副本上用 `codesign --force --sign - [--options runtime] --entitlements …` 重签得到的，副本在 `$S/apps/`。

| 配置 | 结果 |
|---|---|
| 硬化运行时 + DLV，无沙盒（推荐配置） | ALL OK |
| 硬化运行时，无 DLV（App） | dyld 中止，exit 134。最先失败的是包内 ad-hoc 签名的 Sparkle：`mapping process and mapped file (non-platform) have different Team IDs`。ad-hoc 签名之间也算「不同 Team」 |
| 硬化运行时，无 DLV（只链 libMaaCore 的小程序 `$S/cli/check-none`，排除 Sparkle 的干扰） | dyld 中止：`code signature in '…/com.loong.maa/lib/libMaaCore.dylib' not valid for use in process: mapping process and mapped file (non-platform) have different Team IDs` |
| 不开硬化运行时，无 DLV | OK |
| 沙盒 + DLV | 5 个 dylib **能加载**：链接期依赖由 dyld 在启动时映射，早于沙盒初始化。但 2–7 步全部 FAIL，`asst.log` 里是 `Json open failed …/com.loong.maa/resource/config.json`，也就是读资源被沙盒挡住了 |
| 沙盒 + DLV + 只读临时例外（`temporary-exception.files.home-relative-path.read-only`：`/Library/Application Support/com.loong.maa/`、`/Library/Caches/com.loong.maa/`、`/.config/maa-cli/`） | ALL OK |
| 弱链接，rpath 指向一个不存在的目录（`install_name_tool -rpath` 改副本，模拟 `maa update` 期间 `lib/` 被清空） | App 照常启动；预检 `dlsym(RTLD_DEFAULT,"AsstGetVersion") == nil` 检出 Core 缺失，可以给出友好提示 |
| 强链接，rpath 指向不存在的目录（小程序） | dyld 中止，`Library not loaded: @rpath/libMaaCore.dylib`，exit 134 |

## 6. 推荐方案与理由

### 6.1 链接：modulemap + 头文件 + `.tbd` 存根，弱链接（A-weak）

- **构建不依赖 maa-cli，也不复制二进制。** 头文件、modulemap 和 tbd 加起来约 10 KB 文本，可以直接进 fork 仓库（比如放在 `Vendor/MaaCore/`），钉在某个 tag 上，改动能在 diff 里看清。xcframework 方案要么把 21 MB 的 dylib 再复制一份进 xcframework（构建期副本，不重新生成就会和 maa-cli 的漂移），要么让构建依赖本机装好的 maa-cli。
- **弱链接能扛住 `lib/` 暂时缺失。** maa-cli 安装 Core 前会先 `remove_dir_all` 整个 `lib/` 和 `resource/` 再解压（源码 `maa_dirs::ensure_clean`）。强链接时，在这段时间里打开 GUI 会直接被 dyld 中止。弱链接可以照常启动并给出提示。代价是每次启动都要做预检。
- xcframework 方案（B）也能编过、能跑，作为备选。它离上游的结构最近，只需要改路径。

### 6.2 运行时：rpath 指向 `com.loong.maa/lib`，不拷进 App 包

- **整台机器只有一份 Core。** maa-cli 更新后，GUI 下次启动就用上新版，更新源只有 maa-cli 一处，这正是目标。
- **App 包的签名不随 Core 变化。** 外部 dylib 不在 App 的签名封印里，所以换 Core 不需要重签 App，「辅助功能」和「屏幕录制」授权（TCC 按签名身份认）也不会因为换 Core 失效。如果拷进包里，每次换 Core 都要重新拷、重新签，ad-hoc 签名下 TCC 授权会丢。
- App 从 123 MB 降到 34 MB。
- 代价：rpath 在构建时展开 `$(HOME)`，绝对路径写死在二进制里，只适合本机自用，换机器或换用户要重新编译。另外必须带 DLV（或关掉硬化运行时）。

### 6.3 签名与沙盒

- 与 K8 一致：去掉沙盒可行。用 `Apple Development` 证书签名并开着硬化运行时的话，**Release entitlements 必须加 DLV**（上游 `MeoAsstMac.entitlements` 没有，只有 `MAADev.entitlements` 有）。DLV 不需要描述文件。
- 备选：保留沙盒，加三条只读临时例外（§5.1 实测 ALL OK）。这几个权限也不需要描述文件，而且容器内的路径全都不用改。不过 K8 已经定了去沙盒，这里只记录实测结果。

## 7. 障碍与风险清单

1. **库验证**（已解决）：maa-cli 的 dylib 是 `adhoc,linker-signed`，没有 Team ID。开着硬化运行时，不加 DLV 就加载不了，报错原文见 §5.1。
2. **Debug 构建测不出库验证问题**：Debug 配置（`CODE_SIGN_STYLE = Automatic` + identity `-`）签出来的 App，`flags=0x2(adhoc)`，Xcode 没有加 `--options runtime`；Release（Manual + `-`）是 `adhoc,runtime`。所以库验证问题只在 Release 或用真证书签名时才会暴露，验收要用 Release 产物。
3. **沙盒挡资源**：见 §5.1。另外，链接期的 dylib 能在沙盒下加载，只是因为加载早于沙盒初始化；运行中再 `dlopen` 的库（比如 `libMaaAdbControlUnit`）会被沙盒管。
4. **去沙盒后的路径重定位**（S0b §3.3 已提出删目录的问题，这里补全 Core 相关的部分）：
   - `MAAViewModel.userDirectory`（`MAAViewModel.swift:410-412`）是 `applicationSupportDirectory`。去沙盒后它变成 **`~/Library/Application Support` 本身**，Core 会把 `debug/`、`cache/` 直接写进这个目录。要改成 `~/Library/Application Support/<bundle id>/`，而且不能和 maa-cli 的 state 目录共用。
   - 所有 `.documentDirectory` 的用法都会落到 `~/Documents`：`MAAViewModel.swift:271/341/356`（356 行会 `removeItem(<Documents>/resource)`）、`OTAFetcher.swift:16`、`ResourceUpdater.swift:92`、`ResourceUpdateView.swift:155`、`CopilotContent.swift:330`、`InfrastSettingsView.swift:201`、`OpenLogFileView.swift:62`；`.applicationSupportDirectory` 的还有 `OpenLogFileView.swift:55`、`NewViewModel.swift:87`、`Packages/LegacyUserTasks/…/LegacyUserTasks.swift:24/36`（带 `removeItem`）。
   - **因此 spike 没有启动完整的 GUI**，只跑了提前退出的钩子，避免去沙盒的 GUI 在真实家目录里写文件、删文件。
5. **App 包里不再有 `resource/`**：`ResourceUpdater.swift:86` 的 `version()` 读的是 `Bundle.main.resourceURL/resource/version.json`，读不到就抛错，`initialize()` 会直接失败。其他引用见 §8。
6. **资源加载顺序和 maa-cli 不一样**：
   - maa-cli 的顺序：基础资源 → `MaaResource/resource` → `Caches/com.loong.maa/resource`（热更新）→ `~/.config/maa-cli/resource`（`user_resource`）→ 各层的 `global/<client>/resource` → 各层的 `platform_diff/iOS/resource`。
   - GUI 现在的顺序：包内资源 → Documents → OTA 缓存，而且每层加载完立刻接着加载该层的 `platform_diff/iOS`。
   - 区别在于，maa-cli 把平台差异放在最后加载，会覆盖用户资源层。GUI 要和 maa-cli 的行为一致，就要照搬 maa-cli 的顺序。
7. **`maa update` 期间的时间窗**：maa-cli 先删掉整个 `lib/` 和 `resource/`，再解压（`File::create` 写新文件）。
   - 已经在跑的 GUI 还映射着旧文件的 inode，不会因为代码页被改写而崩。
   - 但这段时间里新启动 GUI，强链接会被 dyld 中止（所以推荐弱链接）。
   - Core 有些资源是用到时才读的（`TaskData::lazy_parse`、模板等），GUI 跑任务时如果撞上更新，可能读不到文件。
   - 更新完成后，GUI 进程里的 Core 已经不是盘上那份。要检出这种情况，可以在启动时记下 `libMaaCore.dylib` 的 inode 和 mtime（或者 LC_UUID），开跑前和盘上的比一下。这和 S0b 的「分级」处理一致。
   - MaaResource 是用 git 原地更新的，资源文件也会被改写。
8. **版本漂移 / ABI**：头文件钉在 v6.21.4，Core 跟着 maa-cli 的 Beta 通道走。
   - 如果 `AsstCallerExtra.h` 里的接口被删或改名，强链接时 App 启动就会中止，弱链接时符号变成 NULL，调用就崩。
   - 如果 `struct AsstMapLevelKey` 的布局变了，会**静默读错内存**。
   - 应对：启动时检查 `AsstGetVersion()` 是否在头文件版本的兼容范围内；两个实验接口单独用 `dlsym` 检查是否存在，不在就降级（GUI 只拿它们显示关卡名和物品名）；升级头文件靠脚本，从 `maa version` 对应的 tag 取（见 §8）。
9. **`libMaaAdbControlUnit`**：Core 里有 `dlopen` 和「Failed to load MaaAdbControlUnit library」字样，只有走 MaaFramework 的 ADB 控制器时才会用到。PlayTools / MacSCK 路线用不上，这次也没测。
10. **路径带空格**：`Application Support` 有空格，`LD_RUNPATH_SEARCH_PATHS` 里要加转义引号（写法见 §4.2）。`LIBRARY_SEARCH_PATHS` 指向仓库内的 tbd，避开了这个问题。
11. **Gatekeeper**：本机编出的 App 没有 quarantine，可以直接运行。`spctl --assess` 对 ad-hoc 签名的 App 返回 `rejected`，这是预期结果，本地使用不受影响。如果以后从别处下载构建产物，带上了 quarantine，就要 `xattr -d com.apple.quarantine`。maa-cli 的 dylib 只有 `com.apple.provenance`，加载时不会触发 Gatekeeper。
12. **构建上的小坑（和 Core 无关）**：
    - JBird 的宏插件在命令行构建时要加 `-skipMacroValidation`；在 Xcode 界面里第一次构建，要点一次 Trust & Enable。
    - pbxproj 里有一个没挂 package 的 `JBird` 产品依赖（`830565473042DD6C0077CD3D`），不影响构建。
    - 部署目标 26.0 下多了一些 `Text +` 弃用警告。
13. **本次没测的**：
    - 真连游戏和跑任务（按约束不做）；
    - 用 `Apple Development` 真证书签名（spike 一律 ad-hoc）；
    - 从 LaunchServices（`open`）启动，以及启动完整 GUI（原因见第 4 条）；
    - `libMaaAdbControlUnit` 的 dlopen；
    - maa-cli 升到 0.7.8 后目录布局有没有变（S0b 的 Q7），升级后要复核 §5 的几个路径。
14. **留下的痕迹**：沙盒测试建了容器 `~/Library/Containers/com.hguandl.MeoAsstMac.spikecore`（36 KB）。确认没用后可以手动删除。官方容器 `~/Library/Containers/com.hguandl.MeoAsstMac` 没有碰过（K10）。

## 8. 正式分支要改的地方（只列，不实施）

行号以 `b2c99a8` 为准。

**工程与签名**
1. `MeoAsstMac.xcodeproj/project.pbxproj`：
   - 删掉 5 个 xcframework 的 PBXBuildFile（21-22、55-56、62-63、109-112 行）、Embed Frameworks 里的条目（131-135 行）、Frameworks 阶段里的条目（271-279 行，只删这 5 个）、文件引用（165、200、206、254、255 行）和分组里的条目（290-294 行）；
   - 删掉 `resource` 文件夹引用（257 行）和它在 Resources 阶段的条目；
   - target 的 Debug 和 Release 都加上 `SWIFT_INCLUDE_PATHS = $(SRCROOT)/Vendor/MaaCore/include`、`LIBRARY_SEARCH_PATHS = $(SRCROOT)/Vendor/MaaCore/lib`、`OTHER_LDFLAGS = -weak-lMaaCore`；
   - `LD_RUNPATH_SEARCH_PATHS`（810-813、902-905 行）加上 `"\"$(HOME)/Library/Application Support/com.loong.maa/lib\""`；
   - `MACOSX_DEPLOYMENT_TARGET`（781、872 行）改为 26.0；
   - bundle id、签名身份、Team 按 K8 改。
2. Entitlements（`MeoAsstMac/MeoAsstMac.entitlements`、`MAADev.entitlements`）：按 K8 去掉 `app-sandbox`、`keychain-access-groups` 和只在沙盒里有意义的项（`temporary-exception.mach-lookup`、`files.user-selected`、`network.*`、`device.usb`）；**Release 也要加 `com.apple.security.cs.disable-library-validation`**。`ENABLE_HARDENED_RUNTIME` 保持 YES（或者按 K8 不公证，关掉也行，二选一写进文档）。
3. 新增 `Vendor/MaaCore/`：
   - `include/` 放 5 个头文件，来自 tag；modulemap 里**去掉** `link` 行，链接交给弱链接参数；
   - `lib/libMaaCore.tbd`，只列 `_Asst*`；
   - `PINNED_VERSION`，比如 `v6.21.4`。
4. 新增同步脚本，比如 `tools/sync-maacore.sh`：读 `maa version` 里的 Core 版本，用 `gh api` 取对应 tag 的 `include/`，用 `nm -gU` 重新生成 tbd，并和现有文件 diff，有变化就提示。`AsstCallerExtra.h` 变了要重点看。

**Swift**
5. 启动预检（`MeoAsstMacApp.init()` 或 `MAAViewModel.initialize()` 之前）：`dlsym(RTLD_DEFAULT, "AsstGetVersion")` 为空时显示「maa-cli 的 MaaCore 未找到或正在更新」，不要调任何 `Asst*`。然后比较 `AsstGetVersion()` 和 `PINNED_VERSION` 的兼容范围；`AsstGetMapLevelKey` 和 `AsstGetItemName` 单独用 `dlsym` 检查是否存在。
6. 「GUI 里的 Core 和盘上的是否同一份」：启动时用 `dladdr(AsstGetVersion)` 拿到路径，记下 inode、mtime 或 LC_UUID；开跑前比对，不一致就按 S0b 的分级处理（提示重启 GUI）。
7. `Maa.swift:20-48`（`MAAProvider`）：加 `version()`，按第 5 条给两个实验接口加保护。
8. `MAAViewModel.swift`：
   - `loadResource(channel:)`（337-386 行）、`loadResource(url:channel:)` 和 `loadResource(url:)`（278-305 行）、`reloadResources`（270-273 行）、`fetchOTAResource`（308-332 行）改成照搬 maa-cli 的顺序（§7 第 6 条），去掉包内资源、Documents、OTA 和 `latestVersion` 联网检查（与 S0b 一致）；
   - `userDirectory`（410-412 行）改成独立目录（§7 第 4 条）。
9. 包内资源引用改成 maa-cli 的目录：
   - `Task Configurations/FightConfiguration.swift:95-96`（`item_index.json`，包括 `global/<client>`）；
   - `Configuration Views/InfrastSettingsView.swift:235-240`（`custom_infrast` 内置排班）；
   - `Navigation/CopilotContent.swift:325-327`（`bundledCopilotDirectory`）；
   - `Utils/ResourceUpdater.swift:85-99`（`version()` 改读 maa-cli 的 `version.json`，判断 MaaResource 的新旧要看 git HEAD，见 S0b）；
   - `Navigation/CopilotDetail.swift:172` 只用于 Preview，可以顺手改。
   - 建议集中写一个 `MaaCliPaths`（`base`、`maaResource`、`hotUpdate`、`userResource`、`lib`），不要到处拼字符串。
10. 去沙盒的配套改动（S0b 的 P0 加上 §7 第 4 条的完整清单）：所有 `.documentDirectory` 和 `.applicationSupportDirectory` 的用法改到 App 专属目录，`removeItem` 逐处审查。
11. 删掉 GUI 自己的资源更新和 OTA（`ResourceUpdateView`、`ResourceUpdater`、`OTAFetcher`、`MirrorChyan`、`GitHub` 等），删掉 Sparkle（S0b 和 K8 已定）。

**文档**
12. README 写清：构建不需要 maa-cli，运行需要 `maa install` 过 Core，并且 `~/Library/Application Support/com.loong.maa/lib` 存在；升级 Core 只能通过 maa-cli；头文件的升级流程。
13. `PLAN_MACGUI.md`：S1 的「Core 按 S0a 的结论接入」按本文 §6 和 §8 细化；风险一节「Core 共用」补上 §7 第 7、8 条。

## 9. 复现材料（都在 scratch，会随会话清理）

- 副本：`$S/spike-core`（已加钩子，pbxproj 现在是推荐配置）。完整 diff 在 `$S/patch-recommended-A-weak-rpath.diff`；另外两个变体的 pbxproj diff 是 `$S/patch-A-modulemap-rpath.pbxproj.diff` 和 `$S/patch-B-xcf-embed.pbxproj.diff`。
- 生成 pbxproj：`python3 -I $S/tools/patch_pbxproj.py <原始 pbxproj> <输出> --link {xcf,modulemap} --runtime {rpath,embed} [--weak] --scratch $S`
- 头文件：`$S/maacore-include/v6.21.4/include`；modulemap 加 tbd：`$S/linkA`（带 link）、`$S/linkA-weak`（不带 link）；xcframework：`$S/linkB`、`$S/embed`。
- 构建日志：`$S/build-*.log`；Core 日志：`$S/userdir/*/debug/asst.log`；签名变体：`$S/apps/*.app`；entitlements：`$S/ent/*.plist`；小程序：`$S/cli`、`$S/cli-weak`。
- 运行钩子：`MAA_SPIKE_USER_DIR=$S/userdir/x $S/ddA/Build/Products/Release/MAA.app/Contents/MacOS/MAA`
