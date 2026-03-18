# Export Session Trace

将当前会话的完整执行轨迹导出为可读的文本文件，**不截断任何内容**。

优先从 proxy trace（`~/.claude/traces/`）读取完整的 API 请求/响应数据。如果 proxy trace 不可用，回退到 Claude Code 内置的 JSONL 日志。

## 任务

### Step 1: 确定数据源

检查 `~/.claude/traces/` 目录是否存在且有 `.jsonl` 文件。

- **有 proxy trace**: 使用 proxy trace（包含完整的 system prompt、tool definitions、messages 数组）
- **无 proxy trace**: 回退到 `~/.claude/projects/` 下的 JSONL（部分数据）

### Step 2: 导出脚本

运行下面的 Python 脚本。**不要修改核心逻辑，不要添加截断。**

```python
import json, glob, os, sys

# ── Determine data source ────────────────────────────────────────────────
trace_dir = os.path.expanduser("~/.claude/traces")
proxy_traces = sorted(glob.glob(os.path.join(trace_dir, "*.jsonl"))) if os.path.isdir(trace_dir) else []

# Check for user-specified file
user_arg = "$ARGUMENTS".strip() if "$ARGUMENTS" else ""
if user_arg and os.path.isfile(user_arg):
    source_file = user_arg
    source_type = "proxy" if "/traces/" in user_arg else "jsonl"
elif proxy_traces:
    # Use most recent proxy trace
    source_file = max(proxy_traces, key=os.path.getmtime)
    source_type = "proxy"
else:
    # Fallback to Claude Code JSONL
    jsonl_files = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
    if not jsonl_files:
        print("ERROR: No trace files found. Is the proxy running?")
        sys.exit(1)
    source_file = max(jsonl_files, key=os.path.getmtime)
    source_type = "jsonl"

print(f"Source: {source_file} (type={source_type})")

with open(source_file) as f:
    lines = f.readlines()

out = []
out.append("=" * 80)
out.append("CLAUDE CODE SESSION TRACE (FULL, NO TRUNCATION)")
out.append(f"Source: {source_file}")
out.append(f"Type: {'Proxy trace (full fidelity)' if source_type == 'proxy' else 'JSONL log (partial)'}")
out.append(f"Total entries: {len(lines)}")
out.append("=" * 80)
out.append("")

if source_type == "proxy":
    # ── PROXY TRACE FORMAT ──
    # Pair request/response by reqId, show full API round-trips
    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line.strip()))
        except:
            continue

    # Index responses by reqId
    responses = {}
    for e in entries:
        if e.get("type") == "response":
            responses[e.get("reqId")] = e

    # Show system prompt once (from first request that has it)
    system_shown = False
    turn = 0

    for e in entries:
        if e.get("type") != "request":
            continue

        body = e.get("body") or {}
        resp = responses.get(e.get("reqId"), {})
        resp_body = resp.get("body", {})

        turn += 1
        out.append("─" * 80)
        out.append(f"API CALL #{turn}  @ {e.get('_ts', '?')}")
        out.append(f"  reqId: {e.get('reqId')}")
        out.append(f"  model: {e.get('origModel', '?')} → {body.get('model', '?')}")
        out.append(f"  messages: {e.get('numMessages', '?')}, tools: {e.get('numTools', '?')}")
        out.append(f"  sessionHint: {e.get('sessionHint', '?')}")
        out.append("─" * 80)

        # System prompt (show once)
        if not system_shown and body.get("system"):
            out.append("")
            out.append("┌─ SYSTEM PROMPT ─────────────────────────────────────────────")
            system = body["system"]
            if isinstance(system, list):
                for i, block in enumerate(system):
                    if isinstance(block, dict):
                        text = block.get("text", "")
                        cache = block.get("cache_control", {})
                        out.append(f"  [block {i}] cache={cache}")
                        out.append(f"  {text}")
                    else:
                        out.append(f"  {block}")
                    out.append("")
            else:
                out.append(f"  {system}")
            out.append("└─────────────────────────────────────────────────────────────")
            system_shown = True

        # Tool definitions (show once, just names)
        if turn == 1 and body.get("tools"):
            out.append("")
            out.append(f"┌─ TOOL DEFINITIONS ({len(body['tools'])}) ─────────────────────────────")
            for t in body["tools"]:
                name = t.get("name", "?")
                desc = t.get("description", "")[:80]
                out.append(f"  {name}: {desc}")
            out.append("└─────────────────────────────────────────────────────────────")

        # Messages
        out.append("")
        messages = body.get("messages", [])
        for msg in messages:
            role = msg.get("role", "?")
            content = msg.get("content", "")
            if isinstance(content, str):
                out.append(f"  [{role}] {content}")
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, str):
                        out.append(f"  [{role}] {block}")
                    elif isinstance(block, dict):
                        btype = block.get("type", "?")
                        if btype == "text":
                            out.append(f"  [{role}] {block.get('text', '')}")
                        elif btype == "thinking":
                            out.append(f"  [{role}/thinking] {block.get('thinking', '')}")
                        elif btype == "tool_use":
                            out.append(f"  [{role}/tool_use] {block.get('name', '?')}")
                            out.append(f"    {json.dumps(block.get('input', {}), ensure_ascii=False)}")
                        elif btype == "tool_result":
                            rc = block.get("content", "")
                            err = " (ERROR)" if block.get("is_error") else ""
                            if isinstance(rc, str):
                                out.append(f"  [{role}/tool_result{err}] {rc}")
                            elif isinstance(rc, list):
                                for item in rc:
                                    if isinstance(item, dict) and item.get("type") == "text":
                                        out.append(f"  [{role}/tool_result{err}] {item.get('text', '')}")
                                    else:
                                        out.append(f"  [{role}/tool_result{err}] {json.dumps(item, ensure_ascii=False)}")
                        else:
                            out.append(f"  [{role}/{btype}] {json.dumps(block, ensure_ascii=False)}")

        # Response
        assembled = resp_body.get("assembled") if isinstance(resp_body, dict) else None
        if assembled:
            out.append("")
            out.append(f"  ── RESPONSE (stop={assembled.get('stop_reason', '?')}) ──")
            usage = assembled.get("usage", {})
            if usage:
                out.append(f"  tokens: in={usage.get('input_tokens',0)}, out={usage.get('output_tokens',0)}, cache_read={usage.get('cache_read_input_tokens',0)}, cache_create={usage.get('cache_creation_input_tokens',0)}")
            for block in assembled.get("content", []):
                btype = block.get("type", "?")
                if btype == "text":
                    out.append(f"  [text] {block.get('text', '')}")
                elif btype == "thinking":
                    out.append(f"  [thinking] {block.get('thinking', '')}")
                elif btype == "tool_use":
                    out.append(f"  [tool_use] {block.get('name', '?')}")
                    out.append(f"    {json.dumps(block.get('input', block.get('input_raw', '')), ensure_ascii=False)}")
        elif resp.get("status"):
            out.append(f"  ── RESPONSE status={resp.get('status')} ──")
            out.append(f"  {json.dumps(resp_body, ensure_ascii=False)[:500]}")

        out.append("")

else:
    # ── JSONL FALLBACK FORMAT ── (same as original export-trace)
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
                    out.append(f"  [TOOL: {name}] id={tool_id}")
                    out.append(f"  {json.dumps(inp, ensure_ascii=False, indent=2)}")
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
                else:
                    out.append(f"  [{btype.upper()}]")
                    out.append("  " + json.dumps(block, ensure_ascii=False))
        out.append("")

result = "\n".join(out)
output_path = os.path.expanduser("~/session-trace-full.txt")
with open(output_path, "w") as f:
    f.write(result)
print(f"Output: {output_path}")
print(f"Size: {len(result)} chars, {result.count(chr(10))+1} lines")
```

### Step 3: 报告

告诉用户导出文件的路径、大小、行数，以及数据源类型（proxy trace / JSONL fallback）。

## 用户参数

如果用户通过 `$ARGUMENTS` 指定了文件路径，优先使用用户指定的文件。

## 注意事项

- **绝对不要截断任何内容**，无论多长。完整性是第一优先级。
- Proxy trace 模式下包含完整的 system prompt 和 tool definitions。
- 导出完成后告诉用户文件路径和大小。
