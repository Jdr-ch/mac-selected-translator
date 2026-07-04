# Mac Selected Translator

一个本机 macOS 划词翻译原型：选中文字后按 `Shift+F`、`Shift+F`，在鼠标附近弹出翻译浮层。桌面壳使用 Swift/AppKit，模型层使用 Python + LangChain 调 OpenAI-compatible Qwen。

## 功能

- 全局监听 `Shift+F` 连按两次。
- 优先通过 macOS Accessibility API 读取当前选中文字。
- 对不暴露选中属性的 App，临时执行 `Command+C` 读取剪贴板，并尽量恢复原剪贴板内容。
- 通过本地 HTTP 服务调用 LangChain `ChatOpenAI`。
- 默认模型为 `qwen3.7-max`，默认关闭 Qwen thinking 以降低翻译延迟。
- 翻译结果以可复制浮层显示在鼠标附近。

## 初始化

```bash
cd /Users/jiangdengrui/Documents/AI/mac-selected-translator
./scripts/setup.sh
```

然后编辑 `.env`：

```bash
DASHSCOPE_API_KEY=你的 DashScope 或 Model Studio API Key
QWEN_MODEL=qwen3.7-max
DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
```

如果你的阿里云账号使用 Model Studio 工作空间 endpoint，把 `DASHSCOPE_BASE_URL` 改成控制台给出的完整 OpenAI-compatible `/v1` 地址。

也可以完全不把 API Key 写进 `.env`，直接从当前 shell 环境读取：

```bash
export DASHSCOPE_API_KEY=你的 DashScope 或 Model Studio API Key
./scripts/run_dev.sh
```

启动脚本会优先使用已有环境变量，`.env` 只用于补充未设置的本地默认值。

## 启动

开发模式一条命令启动后端和 Mac App：

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
2. 连续按两次 `Shift+F`。
3. 等待鼠标附近浮层显示译文。

菜单栏会出现一个 `译` 图标，可用于手动触发、检查权限或退出。

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
