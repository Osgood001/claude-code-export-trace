#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  Catcher in the Rye — One-line installer
#  Usage:
#    curl -fsSL <raw-url>/install.sh | bash -s -- --key YOUR_API_KEY
#    curl -fsSL <raw-url>/install.sh | bash -s -- --key YOUR_KEY --target api.other.com --auth bearer
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
TRACE_DIR="$CLAUDE_DIR/traces"
PROXY_FILE="$CLAUDE_DIR/catcher-proxy.mjs"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
COMMANDS_DIR="$CLAUDE_DIR/commands"
START_SCRIPT="$CLAUDE_DIR/catcher-start.sh"
STOP_SCRIPT="$CLAUDE_DIR/catcher-stop.sh"

# Repo raw URL (for fetching files when run via curl pipe)
REPO_RAW="https://raw.githubusercontent.com/osgood001/claude-code-export-trace/main"

# ── Defaults ──────────────────────────────────────────────────────────────
API_KEY=""
TARGET="api.gpugeek.com"
AUTH_MODE="x-api-key"
PORT="18080"
MODEL_MAP=""

# ── Parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)      API_KEY="$2"; shift 2 ;;
    --target)   TARGET="$2"; shift 2 ;;
    --auth)     AUTH_MODE="$2"; shift 2 ;;
    --port)     PORT="$2"; shift 2 ;;
    --models)   MODEL_MAP="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: install.sh --key <API_KEY> [--target <host>] [--auth <mode>] [--port <port>]"
      echo ""
      echo "Options:"
      echo "  --key     API key for the target provider (required)"
      echo "  --target  Target API host (default: api.gpugeek.com)"
      echo "  --auth    Auth mode: x-api-key | bearer | none (default: x-api-key)"
      echo "  --port    Proxy port (default: 18080)"
      echo "  --models  JSON model map override"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$API_KEY" ]]; then
  echo "ERROR: --key is required"
  echo "Usage: install.sh --key <API_KEY> [--target <host>] [--auth <mode>]"
  exit 1
fi

# ── Helper: detect OS ────────────────────────────────────────────────────
detect_os() {
  if [[ "$(uname)" == "Darwin" ]]; then
    OS_TYPE="macos"
  elif [[ -f /etc/debian_version ]]; then
    OS_TYPE="debian"
  elif [[ -f /etc/redhat-release ]]; then
    OS_TYPE="redhat"
  else
    OS_TYPE="unknown"
  fi
}

# ── Helper: install Node.js via nvm (with Chinese mirrors) ──────────────
install_node_via_nvm() {
  echo ""
  echo "  Installing Node.js via nvm (Chinese mirror)..."

  export NVM_DIR="$HOME/.nvm"

  # Install nvm from Gitee mirror (accessible in China)
  curl -fsSL https://gitee.com/mirrors/nvm/raw/v0.40.1/install.sh | bash || true

  # Load nvm
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

  if ! command -v nvm &>/dev/null; then
    echo "  ERROR: nvm installation failed."
    echo "  Please install Node.js 20 manually and re-run this script."
    exit 1
  fi

  # Use Chinese mirror for Node.js binaries
  export NVM_NODEJS_ORG_MIRROR=https://npmmirror.com/mirrors/node

  nvm install 20
  nvm use 20
  nvm alias default 20
  echo "  ✓ Node.js $(node -v) installed via nvm"
}

# ── Helper: configure npm Chinese mirror ─────────────────────────────────
configure_npm_mirror() {
  npm config set registry https://registry.npmmirror.com
  echo "  ✓ npm registry set to npmmirror.com (Chinese mirror)"
}

# ── Helper: install Claude Code CLI ──────────────────────────────────────
install_claude_code() {
  echo "  Installing Claude Code CLI..."
  npm install -g @anthropic-ai/claude-code
  echo "  ✓ Claude Code $(claude --version 2>/dev/null || echo 'installed')"
}

# ── Preflight checks ─────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════╗"
echo "║  Catcher in the Rye — Installer                 ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

detect_os

# ── Step 1: Ensure Node.js 18+ ──────────────────────────────────────────
NEED_NODE=false
if ! command -v node &>/dev/null; then
  NEED_NODE=true
else
  NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_VERSION" -lt 18 ]]; then
    echo "  ⚠ Node.js version too old ($(node -v)), need 18+"
    NEED_NODE=true
  fi
fi

if [[ "$NEED_NODE" == "true" ]]; then
  echo "  Node.js 18+ not found. Installing..."
  install_node_via_nvm
  configure_npm_mirror
else
  echo "  ✓ Node.js $(node -v)"
  # Ensure nvm is loaded if it exists (for npm commands later)
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" 2>/dev/null || true
fi

# ── Step 2: Ensure Claude Code CLI ───────────────────────────────────────
if ! command -v claude &>/dev/null; then
  echo "  Claude Code CLI not found. Installing..."
  configure_npm_mirror
  install_claude_code
else
  echo "  ✓ Claude Code $(claude --version 2>/dev/null || echo 'found')"
fi

# ── Create directories ───────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR" "$TRACE_DIR" "$COMMANDS_DIR"
echo "  ✓ Directories created"

# ── Install proxy ────────────────────────────────────────────────────────
# If running from cloned repo, copy local file; otherwise fetch from GitHub
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}" 2>/dev/null || echo ".")" && pwd)"
if [[ -f "$SCRIPT_DIR/proxy.mjs" ]]; then
  cp "$SCRIPT_DIR/proxy.mjs" "$PROXY_FILE"
else
  curl -fsSL "$REPO_RAW/proxy.mjs" -o "$PROXY_FILE"
fi
echo "  ✓ Proxy installed → $PROXY_FILE"

# ── Install export-trace command ──────────────────────────────────────────
if [[ -f "$SCRIPT_DIR/export-trace.md" ]]; then
  cp "$SCRIPT_DIR/export-trace.md" "$COMMANDS_DIR/export-trace.md"
else
  curl -fsSL "$REPO_RAW/export-trace.md" -o "$COMMANDS_DIR/export-trace.md"
fi
echo "  ✓ /export-trace command installed → $COMMANDS_DIR/export-trace.md"

# ── Write start/stop scripts ─────────────────────────────────────────────
cat > "$START_SCRIPT" << STARTEOF
#!/usr/bin/env bash
# Start the Catcher proxy (background, with nohup)

# Load nvm if present (needed when Node.js was installed via nvm)
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh" 2>/dev/null || true

export CATCHER_API_KEY="$API_KEY"
export CATCHER_TARGET="$TARGET"
export CATCHER_AUTH_MODE="$AUTH_MODE"
export CATCHER_PORT="$PORT"
${MODEL_MAP:+export CATCHER_MODEL_MAP='$MODEL_MAP'}

# Kill existing instance if running
if [[ -f "$CLAUDE_DIR/catcher.pid" ]]; then
  OLD_PID=\$(cat "$CLAUDE_DIR/catcher.pid")
  kill "\$OLD_PID" 2>/dev/null && echo "Stopped old proxy (PID \$OLD_PID)"
  sleep 1
fi

nohup node "$PROXY_FILE" > "$CLAUDE_DIR/catcher.log" 2>&1 &
echo \$! > "$CLAUDE_DIR/catcher.pid"
echo "Catcher proxy started (PID \$!)"
echo "  Log: $CLAUDE_DIR/catcher.log"
echo "  Traces: $TRACE_DIR/"
STARTEOF
chmod +x "$START_SCRIPT"

cat > "$STOP_SCRIPT" << STOPEOF
#!/usr/bin/env bash
# Stop the Catcher proxy
if [[ -f "$CLAUDE_DIR/catcher.pid" ]]; then
  PID=\$(cat "$CLAUDE_DIR/catcher.pid")
  kill "\$PID" 2>/dev/null && echo "Stopped Catcher proxy (PID \$PID)"
  rm -f "$CLAUDE_DIR/catcher.pid"
else
  echo "No Catcher proxy PID file found. Trying pkill..."
  pkill -f "catcher-proxy.mjs" 2>/dev/null && echo "Stopped" || echo "Not running"
fi
STOPEOF
chmod +x "$STOP_SCRIPT"
echo "  ✓ Start/stop scripts → $START_SCRIPT / $STOP_SCRIPT"

# ── Configure settings.json ──────────────────────────────────────────────
# Non-destructive merge: preserve existing settings, only add/update env vars
if [[ -f "$SETTINGS_FILE" ]]; then
  # Backup
  cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak.$(date +%s)"
fi

python3 -c "
import json, os, sys

settings_file = '$SETTINGS_FILE'
try:
    with open(settings_file) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

env = settings.setdefault('env', {})
env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:$PORT'
env['ANTHROPIC_API_KEY'] = 'sk-placeholder-proxy-handles-auth'

# Model name env vars (Claude Code uses these to select models)
# Only set if not already configured by user
if 'ANTHROPIC_DEFAULT_OPUS_MODEL' not in env:
    env['ANTHROPIC_DEFAULT_OPUS_MODEL'] = 'Vendor2/Claude-4.6-Opus'
if 'ANTHROPIC_DEFAULT_SONNET_MODEL' not in env:
    env['ANTHROPIC_DEFAULT_SONNET_MODEL'] = 'Vendor2/Claude-4.6-Sonnet'
if 'ANTHROPIC_DEFAULT_HAIKU_MODEL' not in env:
    env['ANTHROPIC_DEFAULT_HAIKU_MODEL'] = 'Vendor2/Claude-4.6-Sonnet'

with open(settings_file, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('  ✓ settings.json updated (backup saved)')
" || {
  echo "  ⚠ Could not update settings.json automatically."
  echo "    Please add these to $SETTINGS_FILE manually:"
  echo '    "env": {'
  echo "      \"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:$PORT\","
  echo '      "ANTHROPIC_API_KEY": "sk-placeholder-proxy-handles-auth"'
  echo '    }'
}

# ── Start the proxy ──────────────────────────────────────────────────────
echo ""
echo "Starting proxy..."
bash "$START_SCRIPT"

# ── Done ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " Installation complete!"
echo "═══════════════════════════════════════════════════"
echo ""
echo " Usage:"
echo "   claude                          # Start Claude Code (auto-routes through proxy)"
echo "   /export-trace                   # Export full session trace in Claude Code"
echo ""
echo " Management:"
echo "   ~/.claude/catcher-start.sh      # Start proxy"
echo "   ~/.claude/catcher-stop.sh       # Stop proxy"
echo "   tail -f ~/.claude/catcher.log   # Watch proxy log"
echo "   ls ~/.claude/traces/            # View trace files"
echo ""
echo " Traces are saved to:"
echo "   $TRACE_DIR/YYYY-MM-DD.jsonl"
echo ""
