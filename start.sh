#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION="${CC_TMUX_SESSION:-cc-collab}"
PROJECT_DIR="$(pwd)"

G='\033[0;32m' C='\033[0;36m' Y='\033[0;33m' B='\033[1m' D='\033[2m' R='\033[0m'

# ── checks ──
for cmd in tmux jq; do
    command -v "$cmd" &>/dev/null || { echo "Missing: $cmd"; exit 1; }
done
[[ -d ".cc-collab" ]] || { echo "Run setup.sh first"; exit 1; }
[[ -f "$SCRIPT_DIR/relay.sh" ]] || { echo "relay.sh not found"; exit 1; }

# ── kill old session ──
tmux kill-session -t "$SESSION" 2>/dev/null || true

# ── create session (first pane = Claude) ──
tmux new-session -d -s "$SESSION" -c "$PROJECT_DIR"
CLAUDE_ID=$(tmux display-message -t "$SESSION" -p '#{pane_id}')

# ── split right = Codex ──
tmux split-window -h -t "$CLAUDE_ID" -c "$PROJECT_DIR"
CODEX_ID=$(tmux display-message -t "$SESSION" -p '#{pane_id}')

# ── split bottom from Claude = Relay ──
tmux split-window -v -t "$CLAUDE_ID" -c "$PROJECT_DIR" -p 25
RELAY_ID=$(tmux display-message -t "$SESSION" -p '#{pane_id}')

# ── save pane IDs so relay can find them ──
mkdir -p .cc-collab/runtime
echo "$CLAUDE_ID" > .cc-collab/runtime/claude-pane
echo "$CODEX_ID"  > .cc-collab/runtime/codex-pane
echo "$RELAY_ID"  > .cc-collab/runtime/relay-pane
echo "$SESSION"   > .cc-collab/runtime/tmux-session

# ── send commands using pane IDs (not indices) ──
tmux send-keys -t "$CLAUDE_ID" "claude" C-m
tmux send-keys -t "$CODEX_ID"  "codex"  C-m
tmux send-keys -t "$RELAY_ID"  "bash ${SCRIPT_DIR}/relay.sh" C-m

# ── focus Claude ──
tmux select-pane -t "$CLAUDE_ID"

# ── info ──
echo ""
echo -e "${G}Session '${SESSION}' started${R}"
echo -e "  Claude: ${D}${CLAUDE_ID}${R}  Codex: ${D}${CODEX_ID}${R}  Relay: ${D}${RELAY_ID}${R}"
echo ""
echo -e "  ${B}/plan <req>${R} in Claude to begin"
echo -e "  ${D}Ctrl+B arrows${R} switch panes  ${D}Ctrl+B d${R} detach  ${D}tmux attach -t ${SESSION}${R} reattach"
echo ""

[[ -t 0 ]] && tmux attach-session -t "$SESSION"
