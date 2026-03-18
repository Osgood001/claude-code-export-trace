# Export Session Trace

将当前会话的完整执行轨迹导出为可读的文本文件，**不截断任何内容**。

## 任务

1. 找到当前会话的 JSONL 文件。Claude Code 的会话数据存储在 `~/.claude/projects/` 下，按项目路径和 session ID 命名为 `.jsonl` 文件。你需要找到**最近修改的那个 `.jsonl` 文件**作为当前会话。

2. 运行下面的 Python 脚本将 JSONL 解析为完整的、人类可读的文本。**不要修改脚本的核心逻辑，不要添加任何截断。**

3. 将结果同时保存到 `~/session-trace-full.txt` 和 `/storage/emulated/0/Download/session-trace-full.txt`（如果 Download 目录可写的话）。

4. 报告导出文件的大小和行数。

## 导出脚本

```python
import json, glob, os

# 自动找到最近修改的会话 JSONL
jsonl_files = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
if not jsonl_files:
    print("ERROR: 找不到会话 JSONL 文件")
    exit(1)
jsonl_path = max(jsonl_files, key=os.path.getmtime)
print(f"会话文件: {jsonl_path}")

with open(jsonl_path, "r") as f:
    lines = f.readlines()

out = []
out.append("=" * 80)
out.append("CLAUDE CODE SESSION TRACE (FULL, NO TRUNCATION)")
out.append(f"Source: {jsonl_path}")
out.append(f"Total entries: {len(lines)}")
out.append("=" * 80)
out.append("")

for i, line in enumerate(lines):
    try:
        entry = json.loads(line.strip())
    except:
        continue

    etype = entry.get("type", "")
    timestamp = entry.get("timestamp", "")
    msg = entry.get("message", {})

    if not msg:
        if etype == "file-history-snapshot":
            continue
        out.append(f"[{i+1:03d}] ({etype}) {timestamp}")
        out.append("")
        continue

    role = msg.get("role", "?")
    content = msg.get("content", "")
    model = msg.get("model", "")
    stop_reason = msg.get("stop_reason", "")
    usage = msg.get("usage", {})

    header = f"[{i+1:03d}] {role.upper()}"
    if timestamp:
        header += f"  @ {timestamp}"
    if model:
        header += f"  model={model}"
    if usage:
        inp_tok = usage.get("input_tokens", 0)
        out_tok = usage.get("output_tokens", 0)
        cache_read = usage.get("cache_read_input_tokens", 0)
        cache_create = usage.get("cache_creation_input_tokens", 0)
        header += f"  tokens(in={inp_tok},out={out_tok}"
        if cache_read:
            header += f",cache_read={cache_read}"
        if cache_create:
            header += f",cache_create={cache_create}"
        header += ")"
    if stop_reason:
        header += f"  stop={stop_reason}"

    out.append("─" * 70)
    out.append(header)
    out.append("─" * 70)

    if isinstance(content, str):
        out.append(content)
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, str):
                out.append(block)
                continue
            btype = block.get("type", "")

            if btype == "text":
                out.append(block.get("text", ""))

            elif btype == "thinking":
                text = block.get("thinking", "")
                if text:
                    out.append("  [THINKING]")
                    out.append("  " + text.replace("\n", "\n  "))

            elif btype == "tool_use":
                name = block.get("name", "?")
                tool_id = block.get("id", "")
                inp = block.get("input", {})
                inp_str = json.dumps(inp, ensure_ascii=False, indent=2)
                out.append(f"  [TOOL: {name}] id={tool_id}")
                out.append(f"  {inp_str}")

            elif btype == "tool_result":
                tool_use_id = block.get("tool_use_id", "")
                is_err = block.get("is_error", False)
                label = "[TOOL_ERROR]" if is_err else "[TOOL_RESULT]"
                rc = block.get("content", "")
                out.append(f"  {label} tool_use_id={tool_use_id}")
                if isinstance(rc, str):
                    out.append("  " + rc.replace("\n", "\n  "))
                elif isinstance(rc, list):
                    for item in rc:
                        if isinstance(item, dict) and item.get("type") == "text":
                            out.append("  " + item.get("text", "").replace("\n", "\n  "))
                        elif isinstance(item, dict) and item.get("type") == "image":
                            out.append(f"  [IMAGE: {item.get('source', {}).get('type', '?')}]")
                        else:
                            out.append("  " + json.dumps(item, ensure_ascii=False))

            elif btype == "server_tool_use":
                name = block.get("name", "?")
                inp = block.get("input", {})
                out.append(f"  [SERVER_TOOL: {name}]")
                out.append("  " + json.dumps(inp, ensure_ascii=False, indent=2))

            elif btype == "web_search_tool_result":
                out.append("  [WEB_SEARCH_RESULT]")
                out.append("  " + json.dumps(block, ensure_ascii=False))

            else:
                out.append(f"  [{btype.upper()}]")
                out.append("  " + json.dumps(block, ensure_ascii=False))
    out.append("")

result = "\n".join(out)
output_path = os.path.expanduser("~/session-trace-full.txt")
with open(output_path, "w") as f:
    f.write(result)

# 尝试复制到 Download
try:
    dl_path = "/storage/emulated/0/Download/session-trace-full.txt"
    with open(dl_path, "w") as f:
        f.write(result)
    print(f"Also copied to: {dl_path}")
except:
    pass

print(f"Output: {output_path}")
print(f"Size: {len(result)} chars, {result.count(chr(10))+1} lines")
print(f"Entries: {len(lines)}")
```

## 用户参数

如果用户通过 `$ARGUMENTS` 指定了会话 ID 或文件路径，优先使用用户指定的文件，而非自动检测最近的会话。

## 注意事项

- **绝对不要截断任何内容**，无论多长。这是科研用途，完整性是第一优先级。
- 包含完整的 thinking 内容、完整的 tool_result、完整的 tool_use 参数。
- 包含 token 用量统计（input_tokens, output_tokens, cache tokens）。
- 包含 stop_reason。
- 导出完成后告诉用户文件路径和大小。
