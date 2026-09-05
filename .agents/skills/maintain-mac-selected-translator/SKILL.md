---
name: maintain-mac-selected-translator
description: 仅用于 mac-selected-translator（Selected Text Translator，com.local.selected-text-translator）项目的设计迭代、Swift/AppKit 实现、故障诊断、聚焦验证和明确授权后的 App 替换。用户提到本项目的任务栏或菜单栏图标、A/文动画、绿灯与禁止休眠、登录自启动、双屏显示、划词翻译弹窗、候选词留白或替换当前 App 时使用。不要用于其他 macOS 应用、通用 Swift 开发或无关仓库；只有讨论、设计或诊断时不得自动实施或安装。
---

# 划词翻译项目维护

## 先限定项目与动作

1. 从当前工作目录定位 Git 根。原始路径为 `/Users/jiangdengrui/Documents/AI/mac-selected-translator`；移动或克隆后，以 `Package.swift` 中的 `MacSelectedTranslator` / `SelectedTextTranslatorApp`、`Sources/SelectedTextTranslatorApp/` 和构建脚本中的 Bundle ID 交叉确认，不单凭相似目录名套用规则。
2. 将用户的“任务栏图标”映射到本项目的 macOS 菜单栏状态项；区分状态项菜单、划词翻译浮层和 Finder 中的 `.app` 图标。
3. 先读当前源码与目标 diff；把本文参数当作 2026-09-05 的实现基线，不当作永远不变的产品要求。用户最新确认优先。
4. 用户说“给出设计／先设计再做”时，只交付设计和交互说明，等待确认后再改代码。用户只问原因时，先诊断；不得擅自安装、注册登录项或调整 macOS 设置。
5. 保持同一任务续跑。发现文件被其他执行链改动时，停止重叠写入，确认对方已暂停，再读取当前文件和 diff 接着处理；不得用旧缓存覆盖新内容。

## 按职责加载，不全量展开

以下源码路径均相对于项目根；本 Skill 的参考路径相对于本文件。

| 请求 | 先读的源码入口 | 按需参考 |
| --- | --- | --- |
| 菜单点击、双屏图标、A/文动画、绿灯 | `AppDelegate.swift`、`StatusItemIconView.swift`、`SleepPreventionController.swift`，均在 `Sources/SelectedTextTranslatorApp/` | [UI 与交互迭代](references/ui-and-interaction.md) |
| 登录自启动 | `AppDelegate.swift` 的 `registerLaunchAtLoginIfNeeded`、`scripts/build_app.sh` | [构建替换与验收](references/build-and-verification.md) |
| 弹窗美化、候选词高度、复制关闭 | `FloatingPanelController.swift`、`TranslationResultPresentation.swift`，均在 `Sources/SelectedTextTranslatorApp/` | [UI 与交互迭代](references/ui-and-interaction.md) |
| 构建、替换 App、解释验证结果 | `scripts/build_app.sh`、`Package.swift`、本轮目标测试 | [构建替换与验收](references/build-and-verification.md) |
| 修改过程回顾、接手此前版本 | 本轮相关源码与测试 | [UI 与交互迭代](references/ui-and-interaction.md) 中的迭代结论和证据限制 |

其他现有功能仅在用户点名时展开：选区与快捷键从 `AccessibilitySelectionReader.swift` / `HotkeyMonitor.swift` 进入；服务生命周期从 `BackendSupervisor.swift` / `BackendClient.swift` 进入；窗口排列从 `WindowLayoutController.swift` 进入；iPhone 定位从 `IPhoneLocationWindowController.swift` 和 `scripts/iphone_location_bridge.py` 进入。不要因改图标而扫描设备、修改后端模型或重构这些模块。

## 保留产品行为

- 保留 `Option+Tab` 划词翻译、选区读取、鼠标附近浮层、候选词复制后关闭的主链路。
- 将菜单栏图标和绿灯作为一个状态项中的两个命中区域。点击图标打开菜单；禁止休眠开启后，点绿灯只恢复系统正常休眠策略，不打开菜单、不立刻强制电脑睡眠。
- 让休眠状态由 `SleepPreventionController` 单一管理；不要用动画是否存在、绿灯明暗或菜单文字反推业务状态。
- 不因安装升级清空用户配置、钥匙串、权限或登录项。不记录 `.env`、API Key、手机标识等私密内容到 Skill。
- 不把当前分支、PID、某次备份路径、菜单坐标或双屏排列写成固定执行参数；每次涉及这些对象都重新确认。

## 采用一次聚焦闭环

沿用 `implement-focused-feature` 的成功路径、聚焦测试和结构校验，不复制或放宽现有编码规范。执行前明确本轮验证授权与边界；此 Skill 不是每次运行全仓测试、构建或实机操作的授权。

1. 锁定用户点名的行为与直接文件；明确哪些旧行为必须保留。
2. 以源码为依据修正同一事件链或布局链，清理本轮替代掉的旧入口；不叠加无证据的兼容层。
3. 已获验证授权时，运行参考文件中与本轮改动对应的最小测试；测试数量必须大于零。不要重复运行已经有效的检查来凑证据。
4. 用户要求替换 App 时，按参考文件完成旧包备份、构建、签名、精确进程退出、替换、启动和路径／哈希回读；否则止于请求边界。
5. 清楚交付“改了什么、证据覆盖什么、还没验证什么”。用户要求总结时也不得把历史失败改写成成功。

## 不越过证据边界

- `hitTest`、离屏窗口中的 `performClick`、辅助功能点击、真实鼠标点击是不同证据。前三者不能替代最后一项。
- 位图帧测试通过不证明两块物理屏幕都显示正常；安装包哈希一致不证明菜单、绿灯或翻译功能正常。
- **待实测基线（2026-09-05）**：原生图片与 `NSStatusItem.menu` 版本已通过 4 项聚焦测试、Release 构建和安装校验；真实鼠标打开菜单、绿灯独立关闭禁止休眠、切换焦点后的双屏显示尚无该版本的实测确认。之后只有取得对应新证据，才能更新这些结论。
- 桌面工具超时、无法读取无窗口状态项或截图不可用时，说明限制并请求用户执行准确的操作；不要猜坐标、换手段绕过工具规则，或重复宣称“已实机验证”。
