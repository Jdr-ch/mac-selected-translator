# Mac Selected Translator

一个本机 macOS 划词翻译原型：选中文字后按 `Option+Tab`，在鼠标附近弹出翻译浮层。桌面壳使用 Swift/AppKit，模型层使用 Python + LangChain 调 OpenAI-compatible Qwen。

## 功能

- 全局监听 `Option+Tab`。
- 优先通过 macOS Accessibility API 读取当前选中文字。
- 对不暴露选中属性的 App，临时执行 `Command+C` 读取剪贴板，并尽量恢复原剪贴板内容。
- 通过本地 HTTP 服务调用 LangChain `ChatOpenAI`。
- 默认模型为 `qwen3.7-max`，默认关闭 Qwen thinking 以降低翻译延迟。
- 自动判断中英文方向：英文译中文，中文译英文，并给出常用候选译法。
- 选中文本不超过 5 个词时，在主译后显示英文原词或英文主译中每个单词的 IPA 音标。
- 翻译结果以浮层显示在鼠标附近，候选词带浅色背景，点击候选词即可复制并关闭浮层。

## 初始化

```bash
cd /Users/jiangdengrui/Documents/AI/mac-selected-translator
./scripts/setup.sh
```

推荐把 API Key 保存到 macOS 钥匙串，避免在 `.env` 中明文保存：

```bash
export DASHSCOPE_API_KEY=你的APIKey
./scripts/store_api_key_in_keychain.sh
```

## iPhone 定位

菜单栏下拉菜单中的 `iPhone 定位` 可以设置或恢复 iOS 17+ 真机的开发者模拟定位。设备发现和定位模拟通过 `pymobiledevice3` 与 macOS 原生设备隧道完成，运行时不依赖完整 Xcode；重新执行 `./scripts/setup.sh` 可安装新增依赖。

`获取当前定位` 会启动已安装在手机上的 `LocationSimulator` 伴生 App，由它取得用户授权后的真实 `CLLocation`，再通过 USB 读取经纬度。伴生 App 的首次签名和安装仍需要 Xcode：

```text
/Users/jiangdengrui/Documents/Codex/2026-09-01/pin/outputs/LocationSimulator
```

在 Xcode 中选择已连接的 iPhone 运行一次，并在手机上允许定位。之后 Mac 面板可以自动启动伴生 App 并读取当前坐标。

然后编辑 `.env` 中的非敏感配置：

```bash
QWEN_MODEL=qwen3.7-max
DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
```

如果你的阿里云账号使用 Model Studio 工作空间 endpoint，把 `DASHSCOPE_BASE_URL` 改成控制台给出的完整 OpenAI-compatible `/v1` 地址。

开发时也可以只从当前 shell 环境读取：

```bash
export DASHSCOPE_API_KEY=你的APIKey
./scripts/run_dev.sh
```

启动脚本按“当前进程环境 > macOS 钥匙串 > `.env`”的顺序读取 API Key；`.env` 只用于最后兜底和补充非敏感配置。

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

这个 App 会自动检查并启动本地 Python 翻译服务。Finder 双击启动时通常不会继承终端里的 `export DASHSCOPE_API_KEY=...`，因此会自动从 macOS 钥匙串读取已保存的 Key：

```bash
./scripts/store_api_key_in_keychain.sh
```

钥匙串内容会跨注销和重启保留。API Key 失效或轮换后，重新运行该脚本即可覆盖旧值。

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

菜单栏会出现一个 `译` 图标，可用于手动触发、检查权限或退出。译文浮层点击关闭按钮或点击浮层外会隐藏。

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

### Qwen 返回模型或 endpoint 错误

检查 `QWEN_MODEL`、`DASHSCOPE_BASE_URL` 和 API Key 是否属于同一个阿里云账号/工作空间。`qwen3.7-max` 若在你的账号下要求工作空间 endpoint，需要使用控制台提供的 workspace OpenAI-compatible `/v1` 地址。

更新 API Key：

```bash
export DASHSCOPE_API_KEY=新的APIKey
./scripts/store_api_key_in_keychain.sh
```
