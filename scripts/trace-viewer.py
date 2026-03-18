#!/usr/bin/env python3
"""
Catcher in the Rye — Trace Viewer

Reads proxy trace JSONL and outputs human-readable text.

Usage:
    python3 trace-viewer.py                          # latest trace file
    python3 trace-viewer.py ~/.claude/traces/2026-03-18.jsonl
    python3 trace-viewer.py --session "keyword"      # filter by session hint
    python3 trace-viewer.py --summary                # token usage summary only
    python3 trace-viewer.py -o output.txt            # save to file
"""
import json
import glob
import os
import sys
import argparse
from datetime import datetime


def find_latest_trace():
    trace_dir = os.path.expanduser("~/.claude/traces")
    files = glob.glob(os.path.join(trace_dir, "*.jsonl"))
    if not files:
        print(f"No trace files in {trace_dir}", file=sys.stderr)
        sys.exit(1)
    return max(files, key=os.path.getmtime)


def load_entries(path):
    entries = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return entries


def pair_requests(entries):
    """Pair request/response entries by reqId, return list of (req, resp) tuples."""
    responses = {}
    for e in entries:
        if e.get("type") == "response":
            responses[e.get("reqId")] = e

    pairs = []
    for e in entries:
        if e.get("type") == "request":
            resp = responses.get(e.get("reqId"))
            pairs.append((e, resp))
    return pairs


def format_system_prompt(system):
    lines = []
    if isinstance(system, list):
        for i, block in enumerate(system):
            if isinstance(block, dict):
                cache = block.get("cache_control", {})
                text = block.get("text", "")
                lines.append(f"  [block {i}] type={block.get('type', '?')}, cache={cache}")
                lines.append(f"  {text}")
            else:
                lines.append(f"  {block}")
            lines.append("")
    elif isinstance(system, str):
        lines.append(f"  {system}")
    return lines


def format_content_blocks(blocks):
    lines = []
    for block in blocks:
        btype = block.get("type", "?")
        if btype == "text":
            lines.append(f"    [text] {block.get('text', '')}")
        elif btype == "thinking":
            text = block.get("thinking", "")
            lines.append(f"    [thinking] ({len(text)} chars)")
            if text:
                # Show first 500 chars of thinking
                preview = text[:500]
                if len(text) > 500:
                    preview += f"\n      ... ({len(text)} chars total)"
                lines.append(f"      {preview}")
        elif btype == "tool_use":
            inp = block.get("input", block.get("input_raw", ""))
            inp_str = json.dumps(inp, ensure_ascii=False) if isinstance(inp, dict) else str(inp)
            lines.append(f"    [tool_use] {block.get('name', '?')}")
            if len(inp_str) > 200:
                lines.append(f"      {inp_str[:200]}... ({len(inp_str)} chars)")
            else:
                lines.append(f"      {inp_str}")
        elif btype == "tool_result":
            rc = block.get("content", "")
            is_err = block.get("is_error", False)
            label = "tool_error" if is_err else "tool_result"
            if isinstance(rc, str):
                rc_len = len(rc)
            else:
                rc_len = len(json.dumps(rc, ensure_ascii=False))
            lines.append(f"    [{label}] id={block.get('tool_use_id', '?')[:16]} ({rc_len} chars)")
        else:
            lines.append(f"    [{btype}] ...")
    return lines


def format_messages_summary(messages):
    """Short summary of messages array."""
    roles = {}
    for m in messages:
        role = m.get("role", "?")
        roles[role] = roles.get(role, 0) + 1
    parts = [f"{r}={c}" for r, c in sorted(roles.items())]
    return f"{len(messages)} messages ({', '.join(parts)})"


def render_trace(pairs, session_filter=None, summary_only=False):
    out = []
    total_input = 0
    total_output = 0
    total_cache_read = 0
    total_cache_create = 0
    system_shown = False

    filtered = pairs
    if session_filter:
        filtered = [(req, resp) for req, resp in pairs
                     if session_filter.lower() in (req.get("sessionHint", "") or "").lower()]

    out.append("=" * 80)
    out.append("CATCHER IN THE RYE — SESSION TRACE")
    out.append(f"API calls: {len(filtered)}")
    out.append(f"Session filter: {session_filter or '(none)'}")
    out.append("=" * 80)
    out.append("")

    for turn, (req, resp) in enumerate(filtered, 1):
        body = req.get("body") or {}
        resp_body = (resp.get("body") or {}) if resp else {}
        assembled = resp_body.get("assembled") if isinstance(resp_body, dict) else None

        # Token accounting
        usage = (assembled or {}).get("usage", {})
        inp_tok = usage.get("input_tokens", 0)
        out_tok = usage.get("output_tokens", 0)
        cr = usage.get("cache_read_input_tokens", 0)
        cc = usage.get("cache_creation_input_tokens", 0)
        total_input += inp_tok
        total_output += out_tok
        total_cache_read += cr
        total_cache_create += cc

        if summary_only:
            model = req.get("origModel", "?")
            stop = (assembled or {}).get("stop_reason", "?")
            out.append(f"  #{turn:3d}  {req.get('_ts', '?')[:19]}  model={model:30s}  "
                       f"msgs={req.get('numMessages', 0):3d}  tools={req.get('numTools', 0):2d}  "
                       f"in={inp_tok:6d}  out={out_tok:5d}  cache_r={cr:6d}  stop={stop}")
            continue

        out.append("─" * 80)
        out.append(f"API CALL #{turn}  @ {req.get('_ts', '?')}")
        out.append(f"  model: {req.get('origModel', '?')} → {body.get('model', '?')}")
        out.append(f"  {format_messages_summary(body.get('messages', []))}, tools: {req.get('numTools', 0)}")
        out.append("─" * 80)

        # System prompt (once)
        if not system_shown and body.get("system"):
            out.append("")
            out.append("┌─ SYSTEM PROMPT ────────────────────────────────────────────────")
            out.extend(format_system_prompt(body["system"]))
            out.append("└────────────────────────────────────────────────────────────────")
            system_shown = True

        # Tool definitions (once)
        if turn == 1 and body.get("tools"):
            out.append("")
            out.append(f"┌─ TOOL DEFINITIONS ({len(body['tools'])}) ──────────────────────────────────")
            for t in body["tools"]:
                desc = (t.get("description") or "")[:70].split("\n")[0]
                out.append(f"  {t.get('name', '?'):30s}  {desc}")
            out.append("└────────────────────────────────────────────────────────────────")

        # Messages
        out.append("")
        for msg in body.get("messages", []):
            role = msg.get("role", "?")
            content = msg.get("content", "")
            if isinstance(content, str):
                out.append(f"  [{role}] {content}")
            elif isinstance(content, list):
                out.append(f"  [{role}]")
                out.extend(format_content_blocks(content))

        # Response
        if assembled:
            out.append("")
            out.append(f"  ── RESPONSE (stop={assembled.get('stop_reason', '?')}, "
                       f"in={inp_tok}, out={out_tok}, cache_read={cr}, cache_create={cc}) ──")
            for block in assembled.get("content", []):
                btype = block.get("type", "?")
                if btype == "text":
                    out.append(f"  [text] {block.get('text', '')}")
                elif btype == "thinking":
                    text = block.get("thinking", "")
                    out.append(f"  [thinking] ({len(text)} chars)")
                    out.append(f"    {text}")
                elif btype == "tool_use":
                    inp = block.get("input", block.get("input_raw", ""))
                    out.append(f"  [tool_use] {block.get('name', '?')}")
                    out.append(f"    {json.dumps(inp, ensure_ascii=False)}")
        elif resp:
            out.append(f"  ── RESPONSE status={resp.get('status', '?')} ──")

        out.append("")

    # Summary
    out.append("=" * 80)
    out.append("TOKEN USAGE SUMMARY")
    out.append(f"  Total API calls : {len(filtered)}")
    out.append(f"  Input tokens    : {total_input:,}")
    out.append(f"  Output tokens   : {total_output:,}")
    out.append(f"  Cache read      : {total_cache_read:,}")
    out.append(f"  Cache create    : {total_cache_create:,}")
    out.append(f"  Total tokens    : {total_input + total_output:,}")
    out.append("=" * 80)

    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Catcher in the Rye — Trace Viewer")
    parser.add_argument("file", nargs="?", help="Trace JSONL file (default: latest)")
    parser.add_argument("--session", "-s", help="Filter by session hint keyword")
    parser.add_argument("--summary", action="store_true", help="Show token summary only")
    parser.add_argument("-o", "--output", help="Save to file instead of stdout")
    args = parser.parse_args()

    path = args.file or find_latest_trace()
    print(f"Reading: {path}", file=sys.stderr)

    entries = load_entries(path)
    pairs = pair_requests(entries)
    print(f"Found {len(pairs)} API calls", file=sys.stderr)

    result = render_trace(pairs, session_filter=args.session, summary_only=args.summary)

    if args.output:
        with open(args.output, "w") as f:
            f.write(result)
        print(f"Written to: {args.output} ({len(result):,} chars)", file=sys.stderr)
    else:
        print(result)


if __name__ == "__main__":
    main()
