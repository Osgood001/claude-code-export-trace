# Catcher in the Rye

> 麦田里的守望者 — 完整捕获 Claude Code 会话轨迹

Claude Code 通过第三方 API（如 GPUGeek）使用时，本工具作为中间代理，**完整记录每一次 API 请求和响应**，包括 Claude Code 内置日志中缺失的 system prompt、tool definitions、完整 messages 数组等关键数据。

## 背景

我们使用 Claude Code + SOTA 模型进行交互式的科学实验对话。工程师通过 Claude Code 与模型对话，结合已有代码和知识文档，逐步完成实验流程。这个过程中产生的**完整执行轨迹**是核心资产——用于：

1. 复现实验流程
2. 提取可复用的 skill
3. 评估模型自动化能力的上限
4. 为后续使用开源模型替代闭源模型提供基准

Claude Code 内置的 JSONL 日志缺失关键信息（system prompt、tool schema、实际发送的 messages 数组）。本工具通过 proxy 层捕获 100% 完整的 API 交互数据。

## 架构

```
Claude Code  ──HTTP──▶  Catcher Proxy (:18080)  ──HTTPS──▶  API Provider
                              │                              (GPUGeek etc.)
                              ▼
                    ~/.claude/traces/
                    └── 2026-03-18.jsonl   ◀── 完整的 request + response
```

## 安装

### 前提条件

- Linux / macOS / WSL 环境
- Python 3.6+（系统通常自带）
- GPUGeek API Key（或其他兼容 provider 的 key）
- **Node.js 和 Claude Code 无需预装**——安装脚本会自动处理

### 一行安装

```bash
git clone https://github.com/osgood001/claude-code-export-trace.git
cd claude-code-export-trace
bash install.sh --key YOUR_GPUGEEK_API_KEY
```

安装脚本会自动完成**全部配置**：

1. 检测并安装 Node.js 20（如缺失，通过 nvm + 国内镜像安装）
2. 配置 npm 国内镜像（npmmirror.com）
3. 安装 Claude Code CLI
4. 部署 proxy、配置 `settings.json`
5. 安装 `/export-trace` 命令、生成启停脚本
6. 启动 proxy

如果使用非 GPUGeek 的 API Provider：

```bash
bash install.sh --key YOUR_KEY --target api.other-provider.com --auth bearer
```

### 配置 VS Code 插件（推荐）

建议在 VS Code（或 Cursor / Trae 等类 VS Code 编辑器）中安装 **claude for vscode**，通过 IDE 内的终端面板使用 Claude Code。这样可以：

- 直接在编辑器中查看模型的代码修改和输出
- **拖拽或粘贴图片**（如实验截图、能谱图、拟合结果）直接发送给模型
- 通过 `/ide` 命令连接 IDE，让模型直接操作编辑器中的文件
- 更符合日常使用 VS Code 的习惯

安装方式：在 VS Code 扩展市场搜索 **"Claude Code"** 并安装，然后在 VS Code 的终端中启动 `claude`。

### 验证安装

```bash
# 检查 proxy 是否在运行
cat ~/.claude/catcher.log
# 应该看到 "Catcher in the Rye — Claude Code Trace Proxy" 和 "Listening" 字样

# 启动 Claude Code（在 VS Code 终端中）
claude
```

---

## Claude Code 使用规范

安装完成后，按以下规范使用 Claude Code 进行实验，以确保产出**高质量、完整、可复现的轨迹**。

### 启动前配置（每次启动后执行一次）

```
/model                  选择 opus 模型（注意：不要选择 Opus 1M）
/config                 将 auto compact 设置为 true
/ide                    连接 VS Code（如果在 VS Code 终端中启动）
```

### 核心原则：所有操作都在 Claude Code 内完成

**所有非硬件操作均通过 Claude Code 交互完成。** 不要在 Claude Code 之外的终端执行命令。

- 如果需要执行 shell 命令，在 Claude Code 对话中使用英文感叹号：`!<command>`
  ```
  !pip install numpy
  !python my_script.py
  !ls -la
  ```

- **如果在 Claude Code 之外进行了任何操作**（例如实验人员手动调整了仪器参数、修改了配置文件、或环境发生了变化），**必须通过自然语言向模型说明**，以确保上下文的一致性。例如：
  ```
  我刚才手动将 qubit 的 bias 调整到了 0.35V，因为之前的值导致信号完全消失
  ```

### 保持 Session 连续性

一个任务尽量在**一个 session** 中持续对话，确保轨迹完整：

| 场景 | 操作 |
|------|------|
| 正常退出后继续 | `claude -c` 继续上次对话 |
| 选择特定对话继续 | `claude -r` 然后选择 |
| 上下文满了 | 通常会自动 compact（已配置）；如未触发，手动 `/compact` |
| 输错了内容 | `/rewind` 选择并恢复到之前的消息 |
| Claude Code 进入 plan 模式并提示 "clear context and ..." | **不要选 clear context**，直接选 continue，确保轨迹完整 |

### 使用模式

通过 `Shift + Tab` 切换使用模式：

- **default** — 建议日常使用，模型每次编辑/执行前会征求确认
- **accept edits** — 如果对模型较有信心，可以切换到此模式，自动接受编辑

### 其他

- 可以用中文或英文与模型交流，按自己习惯即可
- 可以粘贴文本、代码片段、报错信息；在 VS Code 中还可以直接拖拽/粘贴图片
- 如遇到 API 错误，直接重试即可（API 存在不稳定性，属正常现象）
- 在 Claude Code 中使用 `/export-trace` 可以导出当前会话的完整轨迹

### 项目文件组织

将实验相关的**所有文件**（代码、配置、数据、文档）放入项目文件夹：

```
my-experiment/
├── CLAUDE.md            # 项目指令文件（可选，模型会自动读取）
├── code/                # 实验代码
├── docs/                # 知识文档、论文笔记、设备手册
├── data/                # 数据文件
└── ...
```

这样做的好处：
- 模型可以直接读取和理解所有相关文件
- 模型可以直接修改代码和配置
- 方便打包和复现

---

## Proxy 管理

```bash
~/.claude/catcher-start.sh     # 启动 proxy（自动杀掉旧实例）
~/.claude/catcher-stop.sh      # 停止 proxy
tail -f ~/.claude/catcher.log  # 查看 proxy 实时日志
ls ~/.claude/traces/           # 查看 trace 文件列表
```

## 配置参考

所有配置在 `~/.claude/catcher-start.sh` 中通过环境变量设置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CATCHER_API_KEY` | (必填) | API Key |
| `CATCHER_PORT` | 18080 | Proxy 端口 |
| `CATCHER_TARGET` | api.gpugeek.com | API 地址 |
| `CATCHER_AUTH_MODE` | x-api-key | 认证方式：`x-api-key` / `bearer` / `none` |
| `CATCHER_TRACE_DIR` | ~/.claude/traces | Trace 存储目录 |
| `CATCHER_MODEL_MAP` | (GPUGeek 默认) | JSON model 映射 |

## Trace 文件格式

每天一个文件：`~/.claude/traces/YYYY-MM-DD.jsonl`

每次 API 调用产生两条记录（request + response），通过 `reqId` 配对：

```jsonc
// Request — 包含模型看到的一切
{"type":"request", "reqId":"...", "body":{
  "system": [...],      // 完整 system prompt
  "messages": [...],    // 完整 messages 数组
  "tools": [...],       // 所有 tool definitions
  "model": "...",
  "max_tokens": 16384
}}

// Response — 完整组装的响应
{"type":"response", "reqId":"...", "body":{
  "assembled": {
    "content": [...],   // thinking + text + tool_use blocks
    "usage": {...},     // token 用量
    "stop_reason": "..."
  }
}}
```

## 环境可复现性

为确保实验轨迹可复现：

1. **所有文件放入项目文件夹**——代码、数据、文档，减少外部依赖
2. **记录环境信息**——`pip freeze > requirements.txt`
3. **如有未开源的本地库**——用 Docker/Singularity 打包运行环境
4. **保存 trace 文件**——`~/.claude/traces/*.jsonl`

```bash
# 打包完整的会话数据和项目文件
tar czf session-archive-$(date +%F).tar.gz \
  ~/.claude/traces/ \
  ~/my-experiment/
```

## License

MIT
