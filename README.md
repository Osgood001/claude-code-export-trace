# claude-code-export-trace

A Claude Code custom skill that exports the **full session trace** (no truncation) to a human-readable text file.

## What it does

When invoked via `/export-trace`, it:

1. Automatically locates the current session's JSONL file
2. Parses every message with full content preserved — **no truncation whatsoever**
3. Outputs a readable `.txt` file containing:
   - Every user message, assistant response, thinking process
   - All tool calls with full parameters
   - All tool results with full output
   - Token usage statistics (input, output, cache tokens)
   - Timestamps and model info
4. Saves to `~/session-trace-full.txt` and optionally to Android's Download folder

## Install

Copy the command file into your Claude Code commands directory:

```bash
mkdir -p ~/.claude/commands
cp export-trace.md ~/.claude/commands/
```

Or with curl:

```bash
mkdir -p ~/.claude/commands
curl -o ~/.claude/commands/export-trace.md \
  https://raw.githubusercontent.com/Osgood001/claude-code-export-trace/main/export-trace.md
```

## Usage

In Claude Code, simply type:

```
/export-trace
```

To export a specific session (not the current one):

```
/export-trace ~/.claude/projects/-home/SESSION_ID.jsonl
```

## Output format

```
══════════════════════════════════════════
CLAUDE CODE SESSION TRACE (FULL, NO TRUNCATION)
Source: ~/.claude/projects/-home/xxxx.jsonl
Total entries: 319
══════════════════════════════════════════

──────────────────────────────────────────
[002] USER  @ 2026-03-17T01:21:06.704Z
──────────────────────────────────────────
curl 下来这篇文章，给我梳理一下...

──────────────────────────────────────────
[003] ASSISTANT  @ 2026-03-17T01:21:22.786Z  model=claude-opus-4-6  tokens(in=10,out=3)
──────────────────────────────────────────
  [THINKING]
  The user wants me to...

  [TOOL: WebFetch] id=toolu_xxx
  { "url": "https://...", "prompt": "..." }
```

## Why

Claude Code's built-in export may truncate long tool results and thinking content. For research and debugging purposes, you often need the **complete, untruncated** trace of every interaction. This skill guarantees full fidelity.

## License

MIT
