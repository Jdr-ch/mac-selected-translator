# Mac Selected Translator

一个本机 macOS 划词翻译原型：选中文字后按 `Option+Tab`，在鼠标附近弹出翻译浮层。桌面壳使用 Swift/AppKit，模型层使用 Python + LangChain 调用 Codex 或 Qwen 的既有配置。

## 功能

- 全局监听 `Option+Tab`。
- 优先通过 macOS Accessibility API 读取当前选中文字。
- 对不暴露选中属性的 App，临时执行 `Command+C` 读取剪贴板，并尽量恢复原剪贴板内容。
- 通过本地 HTTP 服务调用 LangChain `ChatOpenAI`。
- 菜单中的“模型切换”提供 Codex / Qwen tabs；点击立即成为翻译和润色的全局默认，重启后保留选择。
- 面板只读显示模型名称和配置来源，并提供 App 内推理强度选择。Codex 默认低强度，Qwen 默认关闭思考；模型、endpoint 和认证仍从各自 CLI 配置读取。
- 生成流程图每次重新打开时默认选择当前全局模型；面板内的 Codex / Qwen 下拉选择只影响本次流程图，保留当前图表、编辑和导出功能。
- 自动判断中英文方向：英文译中文，中文译英文，并给出常用候选译法。
- 选中文本不超过 5 个词时，在主译后显示英文原词或英文主译中每个单词的 IPA 音标。
- 翻译结果以浮层显示在鼠标附近，候选词带浅色背景，点击候选词即可复制并关闭浮层。
- 主译随模型输出逐步显示，音标和候选按完整行随后补齐；仅最终成功结果进入历史。关闭浮层或复制已完成内容会取消本次等待。
- 翻译、润色和流程图的完成提示包含当次模型、强度和耗时，例如 `已生成·codex-中 10.5秒`。耗时由后端本地时钟统计，随结果返回，不增加模型调用；复制结果不包含提示。
- 菜单栏显示电源三态，并按充电状态显示系统输入功率或电池充电功率，点击后左侧查看电源信息，右侧使用原有功能。

## 电源监控

原 A/文图标左侧新增 18 pt 彩色圆角图标：绿色闪电表示正在充电，琥珀色插头表示接电未充电，蓝色电池表示使用电池。内部符号最长边为 15.5 pt。原有圆形绿灯仍只表示禁止休眠，点绿灯仅恢复正常休眠策略。

面板左下角的“菜单栏显示：功率”复选框默认勾选，选择会保留到下次启动。勾选时，正在充电显示电池充电功率，如 `≈25.4 W`；接电未充电显示系统输入功率，如 `68.2 W`。使用电池或取消勾选时仅保留状态图标、隐藏功率数字。电池充电功率按同次读取的电池包电压与充电电流估算，不等于整机输入功率；系统输入功率来自 `AppleSmartBattery.PowerTelemetryData.SystemPowerIn`，由 mW 换算为 W。

左栏展示充电器、供电档位、系统输入电压与功率；未接电时清除旧充电器和输入读数，改为显示电池自身电压。部分 IORegistry 扩展字段随机型或系统版本不同而缺失，缺失时显示 `—` 或“暂不可用”，不补成零值。右栏保留原命令顺序，支持方向键、Enter/Space、Esc；空间不足时两栏分别滚动。

监控通过原生 IOKit 在后台串行读取，共享一份快照，不循环启动命令行进程。面板展开时每秒采样；收起后正在充电每 5 秒、其他状态每 15 秒采样。电源变化事件触发刷新，锁屏和睡眠期间暂停。系统传感器可能不会每秒更新读数。新电源图标保持静态，仅内容或主题变化时绘制，原有 A/文动画仍使用独立的 44 × 22 pt 位图。

除原有 IOPS 电源状态通知外，还监听 `AppleSmartBattery` 的 `kIOPMMessageBatteryStatusHasChanged` 消息：驱动发布新电池数据后立即读取同一快照，不必等下一次周期采样。该消息属于私有接口，订阅不可用时继续依靠原有通知和轮询。锁屏、睡眠或停止监控时释放设备监听，恢复后重新订阅；事件和定时请求仍合并为最多一个在途读取及一次待刷新。`SystemPowerIn` 在本机实测中约每 60 秒发布一批新值，这不是所有机型的固定周期；通知减少的是新值发布后等待下一次轮询的延迟。

功率开关只用已有快照更新显示，不新增硬件查询、计时器或动画。菜单栏功率保留一位小数，格式化结果不变时复用缓存；关闭功率显示后，功率读数变化不会重绘菜单栏前缀。面板中的详细指标仍按原采样节奏更新。

## 初始化

```bash
cd /Users/jiangdengrui/Documents/AI/mac-selected-translator
./scripts/setup.sh
```

## 模型来源

| Tab | 配置来源 | 认证来源 |
| --- | --- | --- |
| Codex | `~/.codex/config.toml` 的当前 model、provider、wire_api 和推理参数 | provider 指定的 `env_key`；未指定时读取 `~/.codex/auth.json` 的 `OPENAI_API_KEY` |
| Qwen | `~/.qwen/settings.json` 的 `model.name`、`model.baseUrl` 及匹配的 `modelProviders.openai` 配置 | 匹配项的 `envKey`，优先在该文件的 `env` 中解析，否则读取进程环境 |

当前支持两者的 API Key 接入；不将 CLI 的 OAuth 登录态当作 API Key 使用。Qwen 使用模型名与 Base URL 同时匹配，避免同名的标准服务与 Coding Plan 混用密钥。

首次默认选择 Qwen。打开面板、切换 tab、重新激活面板以及每次模型请求都会重新读取源配置；源配置错误时显示提示，不自动换用其他模型。请求开始后使用固定配置快照。App 在 UserDefaults 中保存 `modelSelection.provider` 和按模型区分的 `modelSelection.reasoning.*`，仅覆盖 App 请求的推理参数，不改写上述文件或钥匙串。

后端在服务生命周期内复用 HTTP 连接池，优先协商 HTTP/2，减少重复 TCP/TLS 建连；模型、地址和认证仍逐次读取。仅支持 HTTP/1.1 的服务会自动回退，连接能否复用取决于响应是否完整读取及服务端策略。流式显示沿用原来的翻译请求和最多一次 IPA 修正，不额外调用模型。升级需安装新增的 HTTP/2 依赖并重启后端，以启用 `/translate` 的 NDJSON 流式响应。

`.env` 只加载本地服务运行参数，旧的 `QWEN_MODEL`、`DASHSCOPE_BASE_URL` 和密钥配置不再作为模型来源。

模型请求的默认等待时间为 120 秒，可通过运行参数 `TRANSLATOR_REQUEST_TIMEOUT_SECONDS` 调整；旧的 `QWEN_REQUEST_TIMEOUT_SECONDS` 不再读取。客户端从 `/health` 获取等待预算，翻译会预留一次音标补全请求的时间，润色和流程图按一次模型请求等待。超时会明确提示，不再误报为认证配置错误。

流程图通过 `/flowchart` 的 `provider` 字段使用同一配置读取链路，不再保存或发送自定义模型名。面板保持打开时，再次展开下拉框或从菜单唤起不会重置局部选择；关闭后重开才跟随最新全局选择。

## iPhone 定位

菜单栏下拉菜单中的 `iPhone 定位` 可以设置或恢复 iOS 17+ 真机的开发者模拟定位。设备发现和定位模拟通过 `pymobiledevice3` 与 macOS 原生设备隧道完成，运行时不依赖完整 Xcode；重新执行 `./scripts/setup.sh` 可安装新增依赖。

`获取当前定位` 会启动已安装在手机上的 `LocationSimulator` 伴生 App，由它取得用户授权后的真实 `CLLocation`，再通过 USB 读取经纬度。伴生 App 的首次签名和安装仍需要 Xcode：

```text
/Users/jiangdengrui/Documents/Codex/2026-09-01/pin/outputs/LocationSimulator
```

在 Xcode 中选择已连接的 iPhone 运行一次，并在手机上允许定位。之后 Mac 面板可以自动启动伴生 App 并读取当前坐标。

## 启动

### 像普通 App 一样启动

生成双击可启动的 `.app`：

```bash
cd /Users/jiangdengrui/Documents/AI/mac-selected-translator
./scripts/build_app.sh
```

生成后可以直接双击：

```text
/Users/jiangdengrui/Documents/AI/mac-selected-translator/dist/Selected Text Translator.app
```

也可以命令行打开：

```bash
./scripts/open_app.sh
```

这个 App 会自动检查并启动本地 Python 服务，菜单不再提供手动检查/启动入口。服务启动不依赖模型凭证，读取配置或发起请求时才检查所选模型。

若旧版 App 启动的后端仍占用同一端口，需先退出旧版 App 及其服务。新 App 会检查后端的模型切换能力，避免旧服务忽略 Codex 选择而实际调用 Qwen。

### 开发模式

开发模式仍然可以一条命令启动后端和 Mac App：

```bash
cd /Users/jiangdengrui/Documents/AI/mac-selected-translator
./scripts/run_dev.sh
```

首次运行时 macOS 会要求授权。请到：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

允许当前终端或编译出的 `SelectedTextTranslatorApp`。授权后重新启动工具。

## 使用

1. 在任意 App 中选中一段文字。
2. 按 `Option+Tab`。
3. 等待鼠标附近浮层显示译文；不超过 5 个词时会同时显示英文 IPA 音标，候选词仍可点击复制。

短词结果示例：

```text
主译：标准化的
音标：standardized /ˈstændərdaɪzd/
候选：
- 标准化的（通用）
- 规范化的（流程/格式）
```

菜单栏会出现电源状态与 A/文图标，点击打开双栏面板，可查看电源信息、手动触发、检查权限或退出。译文浮层点击关闭按钮或点击浮层外会隐藏。

## 单独启动

后端：

```bash
./scripts/run_backend.sh
```

Mac App：

```bash
./scripts/run_app.sh
```

构建 release：

```bash
./scripts/build_release.sh
```

## 常见问题

### 无法读取选中文字

确认已授予辅助功能权限。部分受保护输入框、密码框或 Electron/WebView 特殊区域可能不暴露选中内容，此时工具会尝试剪贴板回退读取。

### 后端连接失败

先检查本地服务：

```bash
curl http://127.0.0.1:8765/health
```

如果端口被占用，可在 `.env` 里同时修改：

```bash
TRANSLATOR_BACKEND_PORT=8766
TRANSLATOR_BACKEND_URL=http://127.0.0.1:8766
```

### 模型配置读取失败

检查面板所示的 `.codex/config.toml` 或 `.qwen/settings.json`，在对应 CLI 中维护配置后重新打开面板。界面不会展示密钥、提供编辑入口或用旧配置兜底。
