# Catcher in the Rye

> 麦田里的守望者 — 完整捕获 Claude Code 会话轨迹

Claude Code 通过第三方 API（如 GPUGeek）使用时，本工具作为中间代理，**完整记录每一次 API 请求和响应**，包括 Claude Code 内置日志中缺失的 system prompt、tool definitions、完整 messages 数组等关键数据。

## 背景

我们使用 Claude Code + SOTA 模型进行量子芯片 Calibration 的自动化实验。工程师通过交互式对话，结合已有代码和知识文档，逐步完成校准流程（S21 → Spectrum → Rabi → T1 → Ramsey 等）。这个过程中产生的**完整执行轨迹**是核心资产——用于：

1. 复现实验流程
2. 提取可复用的 skill
3. 评估模型自动化能力的上限
4. 为后续使用开源模型替代闭源模型提供基准

Claude Code 内置的 `~/.claude/projects/` JSONL 日志缺失关键信息（system prompt、tool schema、实际发送的 messages 数组）。本工具通过 proxy 层捕获 100% 完整的 API 交互数据。

## 架构

```
Claude Code  ──HTTP──▶  Catcher Proxy (:18080)  ──HTTPS──▶  API Provider
                              │                              (GPUGeek etc.)
                              ▼
                    ~/.claude/traces/
                    └── 2026-03-18.jsonl   ◀── 完整的 request + response
```

Proxy 做三件事：
1. **Auth 转换** — Claude Code 的 Bearer token → 目标 API 的认证方式
2. **Model 名称映射** — `claude-opus-4-6` → `Vendor2/Claude-4.6-opus` 等
3. **完整记录** — 每次 API 调用的 request body（含 system prompt、messages、tools）和 response（SSE 流组装为完整消息）

## 捕获的数据 vs Claude Code 内置日志

| 数据 | 内置 JSONL | Proxy Trace |
|------|:---------:|:-----------:|
| User messages | Y | Y |
| Assistant responses | Y | Y |
| Thinking blocks | Y | Y |
| Tool calls & results | Y | Y |
| Token usage | Y | Y |
| **System prompt** | **N** | **Y** |
| **Tool definitions (JSON Schema)** | **N** | **Y** |
| **完整 messages 数组** | **N** | **Y** |
| **Sidecar model 调用** | **N** | **Y** |
| **API 请求参数** | **N** | **Y** |
| **Cache breakpoints** | **N** | **Y** |

## 安装

### 前提条件

- Node.js 18+
- Python 3.6+（用于 trace-viewer 和配置脚本）
- Claude Code CLI（`npm install -g @anthropic-ai/claude-code`）
- 一个 API Key（GPUGeek 或其他兼容 provider）

### 一行安装（GPUGeek）

```bash
git clone https://github.com/osgood001/claude-code-export-trace.git
cd claude-code-export-trace
bash install.sh --key YOUR_GPUGEEK_API_KEY
```

或直接：

```bash
curl -fsSL https://raw.githubusercontent.com/osgood001/claude-code-export-trace/main/install.sh | bash -s -- --key YOUR_GPUGEEK_API_KEY
```

### 安装（其他 API Provider）

```bash
bash install.sh --key YOUR_KEY --target api.other-provider.com --auth bearer
```

### 安装做了什么

1. 检查 Node.js 版本
2. 将 `proxy.mjs` 安装到 `~/.claude/catcher-proxy.mjs`
3. 将 `/export-trace` 命令安装到 `~/.claude/commands/`
4. 创建 `~/.claude/traces/` 目录
5. 配置 `~/.claude/settings.json`（非破坏性合并，保留已有设置）
6. 生成 `~/.claude/catcher-start.sh` 和 `~/.claude/catcher-stop.sh`
7. 自动启动 proxy

## 使用

### 日常使用

```bash
# 1. 确保 proxy 在运行
~/.claude/catcher-start.sh

# 2. 正常使用 Claude Code（自动走 proxy）
claude

# 3. 结束后导出轨迹
#    方式 A: 在 Claude Code 中使用 slash command
/export-trace

#    方式 B: 用 trace-viewer 直接查看
python3 scripts/trace-viewer.py

#    方式 C: 查看 token 用量摘要
python3 scripts/trace-viewer.py --summary
```

### Proxy 管理

```bash
~/.claude/catcher-start.sh     # 启动（自动杀掉旧实例）
~/.claude/catcher-stop.sh      # 停止
tail -f ~/.claude/catcher.log  # 实时日志
ls ~/.claude/traces/           # 查看 trace 文件
```

### Trace 查看

```bash
# 查看最新 trace（默认）
python3 scripts/trace-viewer.py

# 查看指定日期
python3 scripts/trace-viewer.py ~/.claude/traces/2026-03-18.jsonl

# 只看 token 用量
python3 scripts/trace-viewer.py --summary

# 按会话关键词过滤（多会话并发时有用）
python3 scripts/trace-viewer.py --session "calibration"

# 导出到文件
python3 scripts/trace-viewer.py -o trace-output.txt
```

## 配置

所有配置通过环境变量，在 `~/.claude/catcher-start.sh` 中设置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CATCHER_API_KEY` | (必填) | 目标 API 的 key |
| `CATCHER_PORT` | 18080 | Proxy 监听端口 |
| `CATCHER_TARGET` | api.gpugeek.com | 目标 API 地址 |
| `CATCHER_AUTH_MODE` | x-api-key | 认证方式：`x-api-key` / `bearer` / `none` |
| `CATCHER_TRACE_DIR` | ~/.claude/traces | Trace 存储目录 |
| `CATCHER_MODEL_MAP` | (见下) | JSON 格式的 model 名称映射 |

### Model 映射

默认映射（GPUGeek）：

```json
{
  "claude-opus-4-6": "Vendor2/Claude-4.6-opus",
  "claude-sonnet-4-6": "Vendor2/Claude-4.5-Sonnet",
  "claude-haiku-4-5-20251001": "Vendor2/Claude-4.5-Sonnet"
}
```

自定义映射：
```bash
export CATCHER_MODEL_MAP='{"claude-opus-4-6":"your-provider/claude-opus"}'
```

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

为确保实验轨迹可复现，建议：

1. **记录环境信息**：Python 版本、已安装的包（`pip freeze > requirements.txt`）
2. **打包本地代码库**：如果使用了未开源的库，用 Docker/Singularity 打包
3. **保存 trace 文件**：`~/.claude/traces/*.jsonl` 是完整的 API 级记录
4. **保存 Claude Code 日志**：`~/.claude/projects/` 下的 JSONL 作为补充

```bash
# 打包完整的会话数据
tar czf session-archive-$(date +%F).tar.gz \
  ~/.claude/traces/ \
  ~/.claude/projects/
```

## 文件结构

```
claude-code-export-trace/
├── README.md              # 本文件
├── LICENSE                # MIT
├── install.sh             # 一键安装脚本
├── proxy.mjs              # 代理 + 轨迹捕获 (Node.js, 零依赖)
├── export-trace.md        # Claude Code /export-trace 命令
└── scripts/
    └── trace-viewer.py    # 轨迹查看工具 (Python, 零依赖)
```

## License

MIT
