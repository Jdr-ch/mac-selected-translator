# 构建替换与验收

只在当前请求明确要求构建、测试、替换 App，或适用规则的门禁要求时执行相应命令。仅写方案、解释问题或维护本文，不触发 App 构建、安装和真实桌面操作。

## 先选择证据，不扩大验证范围

以下命令在已确认的项目根运行。只选择对应本轮改动的一组，不默认全部运行：

菜单栏与动画：

```bash
swift test --filter 'SelectedTextTranslatorAppTests.WindowLayoutPlannerTests/(testStatusItemVisualStyleCombinesTranslationIconAndSleepLight|statusIcon)'
```

候选行高度：

```bash
swift test --filter 'SelectedTextTranslatorAppTests.TranslationResultPresentationTests/candidateRowsUseCompactHeight'
```

涉及结果解析或候选复制协议时，使用整个直接相关的 `TranslationResultPresentationTests`：

```bash
swift test --filter 'SelectedTextTranslatorAppTests.TranslationResultPresentationTests'
```

- 以上名称来自 2026-09-05 源码，后续可随测试重命名调整。出现 `No matching test cases were run` 或最后 `Test run with 0 tests` 时，先用 `swift test list` 获取精确名称再修正筛选。
- 此项目使用 Swift Testing，完整名称包含 `模块.Suite/方法()`。不要把 Suite 与方法间的 `/` 写成 `.`。
- Swift 命令可能先输出 XCTest 的 `Executed 0 tests`，随后才运行 Swift Testing。以最终 Swift Testing 的实际数量与失败结果判定，不机械地把前面的零判为失败，也不能只看退出码为 0。
- 聚焦测试仍可能编译测试 target 的其他文件。若被无关编译错误阻断，说明原因与可用的局部证据，不擅自修复无关模块，也不宣称测试已通过。
- 授权范围内做目标 diff 空白检查和适用编码门禁；已有有效检查不重复执行。不因一次成功校验而声称完整 lint、全量测试或真实设备验收通过。

## 证据能证明什么

| 证据 | 能证明 | 不能证明 |
| --- | --- | --- |
| native image／pose／hitTarget 单元测试 | 位图有内容和尺寸、动画数值、绿灯几何路由 | 已安装 App 收到了实际鼠标事件；双屏都可见 |
| 离屏 `NSWindow` 中按钮的 `performClick` | 该测试环境的 target-action 可投递 | 菜单栏实际命中、复制菜单栏的鼠标分发 |
| 辅助功能操作后读到菜单项 | AX 路径可调用菜单，菜单内容存在 | 用户鼠标能打开菜单 |
| Release 编译与签名有效 | 包可构建，签名结构通过本次检查 | Gatekeeper、登录自启动或业务交互已实测 |
| dist／安装包哈希一致，进程路径正确 | 启动的是本次安装的可执行文件 | 菜单、翻译、绿灯与双屏功能正确 |
| 针对本版本的真实鼠标和双屏操作 | 被实际执行的那几条用户流程 | 未执行的其他流程、其他机器或系统版本 |

## 构建：复用项目现有脚本

先读 `scripts/build_app.sh`，确认生成目录仍是项目内的 `dist/Selected Text Translator.app`，再运行：

```bash
./scripts/build_app.sh
```

该脚本当前负责 Swift Release 编译、App bundle、`scripts/generate_app_icon.swift` → iconset → `AppIcon.icns`、plist 和 ad-hoc 签名。它会重建 dist 中的旧包；不改写一份平行构建流程，不拿安装目录当构建临时目录。

回读而不是凭记忆假定：

- `CFBundleIdentifier` 应为 `com.local.selected-text-translator`，可执行文件为 `SelectedTextTranslatorApp`。
- `CFBundleIconFile` 应指向 `AppIcon`，且 `Contents/Resources/AppIcon.icns` 确实存在。
- `LSUIElement` 是后台菜单栏应用配置；没有普通主窗口不等于没有运行。
- `TranslatorProjectRoot` 必须指向本轮使用的真实项目根。仓库移动时重新构建，不能复制仍引用旧路径的包冒充新安装。
- App 图标与菜单栏图标共享 A/文的视觉语言，但由不同代码生成；修改其中一个时，按用户范围决定是否同步另一个。

## 替换：精确目标与可回退操作

用户要求“替换当前 App”时完成以下顺序；只有“构建”则止于产物，不擅自退出或覆盖已安装 App。

1. 用只读检查解析当前安装路径、Bundle ID、运行进程的完整路径／PID、目标目录及备份目录。默认安装路径为 `/Applications/Selected Text Translator.app`，但以本机当前事实和用户指定为准。
2. 构建成功后先验证 dist 包签名与所需资源。新包未通过时不动当前安装。
3. 选择不存在的精确备份名，例如废纸篓下 `Selected Text Translator-before-<本次本地日期时间>.app`；实际执行前展开并回读。不要复用本会话旧 PID、日期或备份路径，不覆盖已有备份。
4. 只终止已核实属于该安装包的进程，优先正常退出／`TERM`，再确认其退出。注意退出会释放当前禁止休眠 activity 并关闭本 App 所有窗口；不要广泛 `pkill` Python、Swift 或其他应用。
5. 把旧 App 移到该备份路径，再用 `ditto` 将 dist 包复制到精确安装路径。遇到失败先保留备份并报告或回滚，不进行递归强删。
6. 启动精确的新安装路径，然后核对签名、可执行文件 SHA-256、plist 项目根及进程完整路径。只看到 `open` 成功不足以判定进程已正常运行。
7. 若安装失败需要回退，先确认新 App 已退出及两个包的身份，再保留失败新包、恢复旧包并回读。不清空整个废纸篓、dist、用户目录或权限数据库。
8. 交付当前 App 位置、哪些校验通过、旧包位置和实测缺口。不把备份移动描述为永久删除；本流程不授权 Git 提交／推送。

常用只读校验（路径只在与本轮目标一致时使用）：

```bash
codesign --verify --deep --strict --verbose=2 'dist/Selected Text Translator.app'
codesign --verify --deep --strict --verbose=2 '/Applications/Selected Text Translator.app'
shasum -a 256 'dist/Selected Text Translator.app/Contents/MacOS/SelectedTextTranslatorApp' '/Applications/Selected Text Translator.app/Contents/MacOS/SelectedTextTranslatorApp'
/usr/libexec/PlistBuddy -c 'Print :TranslatorProjectRoot' '/Applications/Selected Text Translator.app/Contents/Info.plist'
ps -ax -o pid=,comm= | rg 'SelectedTextTranslatorApp$'
```

## 登录自启动与真实验收

- 自启动入口是 `AppDelegate.registerLaunchAtLoginIfNeeded`：仅对 `.app` bundle，在 `SMAppService.mainApp.status == .notRegistered` 时调用注册。保留用户禁用或需要批准的状态，不循环强制重新注册。
- “开机自启动”在此实现为用户登录后启动，不等于登录前的系统服务。注册调用成功与实际重新登录后启动是两种证据；没有实际登录测试就标为未验证。
- 对签名／权限变化先检查当前状态；不要为方便测试重置 TCC、替用户开启权限、修改系统安全配置或重启／登出用户。
- 桌面验证使用当前可用且合规的工具。以往工具读取该 LSUIElement 进程曾报 `timeoutReached`，不把它永久当成环境事实；重试需有新条件。工具不可用时让用户在两块屏幕分别点击图标、切换焦点并测试绿灯，不拿 AX 回读替代这些动作。
- 仅报告实际执行的验收：图标鼠标展开菜单、绿灯解除禁止休眠、待机分段与翻译中反馈、双屏焦点切换、候选复制并关闭。按本轮范围选择，不为每次小修都重跑完整清单。
