#!/usr/bin/env bash
#
# setup.sh - Claude Code + Codex v2 collaboration init
#
set -euo pipefail

G='\033[0;32m' C='\033[0;36m' D='\033[2m' B='\033[1m' R='\033[0m'
info() { echo -e "${G}[setup]${R} $*"; }

# ── 1. directories ──
info "Creating .cc-collab/ ..."
mkdir -p .cc-collab/queue/claude .cc-collab/queue/codex \
         .cc-collab/archive .cc-collab/state \
         .cc-collab/logs .cc-collab/runtime

# ── 2. CLAUDE.md ──
MARKER="## CC-COLLAB: Collaboration Protocol v2"
if [[ -f CLAUDE.md ]] && grep -qF "$MARKER" CLAUDE.md; then
    info "CLAUDE.md already has v2 protocol, skipping"
else
    info "Appending collaboration protocol to CLAUDE.md ..."
    cat >> CLAUDE.md <<'CLAUDE_PROTOCOL'

## CC-COLLAB: Collaboration Protocol v2

### CRITICAL RULE — READ THIS FIRST

When using /plan, /next, or /handoff commands, you MUST write output to a FILE
in .cc-collab/queue/codex/ using the bash tool. Do NOT just reply in the terminal.

- Use bash to create the file (cat > path << 'EOF' ... EOF)
- Your terminal reply should be ONE LINE confirming the file was written
- If you only respond in the terminal without writing a file, the relay cannot
  detect your output and the workflow breaks completely

This is the single most important rule. Everything else is secondary.

### Your Role
You are the planner and reviewer in a Claude Code + Codex CLI collaboration.

### Communication
- Send to Codex: write files to .cc-collab/queue/codex/
- Receive from Codex: read files from .cc-collab/queue/claude/

### Sequence Numbering
Run: ls .cc-collab/queue/codex/ .cc-collab/queue/claude/ 2>/dev/null | grep -oP '^\d+' | sort -n | tail -1
Add 1, zero-pad to 4 digits. If empty, start at 0001.

### Message Format (MANDATORY)
```markdown
---
id: "NNNN"
from: claude
to: codex
type: plan|execute|critique|review|done|needs_human
round: N
reply_to: "NNNN"
status: pending
created_at: YYYY-MM-DDTHH:MM:SS+TZ
---

## Objective
[What needs to be accomplished]

## Scope
[In scope / out of scope]

## Constraints
[Technical or business constraints]

## Acceptance Criteria
[REQUIRED for execute type]

## Implementation Suggestions
[Concrete steps with code snippets]

## Fallback
[What to do if primary approach fails]
```

### Atomic Write Rule
1. Write to .tmp first: NNNN-type.md.tmp
2. Rename: mv NNNN-type.md.tmp NNNN-type.md
3. Relay only reads .md files, never .tmp

### Message Types
- plan: high-level plan (analysis phase)
- execute: concrete instructions (MUST have acceptance criteria)
- critique: feedback on proposals
- review: review of completed work
- done: task complete (include verification + residual risks)
- needs_human: cannot proceed without human

### Fast Path (trivial fixes)
If a fix is 5 lines or fewer AND does not change architecture or interfaces:
- Fix it DIRECTLY in the code yourself — do NOT write to the queue
- Tell the user what you fixed in the terminal
- This skips the full protocol overhead for simple changes

### Mandatory Tests
Before emitting any done message you MUST verify:
- Critical business logic has unit tests
- Error handling branches are tested
- Input validation is tested
If tests are missing, write an execute message to Codex requesting tests BEFORE done.

### Rules
- Do NOT assume Codex saw your terminal output
- Do NOT emit execute without acceptance criteria
- Do NOT modify Codex message files — always create new ones
- Do NOT send done/review/needs_human messages to Codex — relay will skip them
- If complete, emit done — do not start another round
CLAUDE_PROTOCOL
fi

# ── 3. AGENTS.md ──
info "Creating AGENTS.md ..."
cat > AGENTS.md <<'AGENTS_PROTOCOL'
## CC-COLLAB: Collaboration Protocol v2

You are the executor in a Claude Code + Codex CLI collaboration.

### CRITICAL RULE
When asked to execute a task, you MUST write your result to a FILE in
.cc-collab/queue/claude/ using the shell. Do NOT just reply in the terminal.

### Communication
- Receive from Claude: read .cc-collab/queue/codex/
- Send to Claude: write to .cc-collab/queue/claude/

### Sequence Numbering
Run: ls .cc-collab/queue/codex/ .cc-collab/queue/claude/ 2>/dev/null | grep -oP '^\d+' | sort -n | tail -1
Add 1, zero-pad to 4 digits.

### Message Format (MANDATORY)
```markdown
---
id: "NNNN"
from: codex
to: claude
type: progress|done|blocked|critique
round: N
reply_to: "NNNN"
status: pending
created_at: YYYY-MM-DDTHH:MM:SS+TZ
---

## Status
[Success / Partial / Failed / Blocked]

## Completed Work
[What you did]

## Files Created or Modified
[Paths + descriptions]

## Verification Results
[Tests/checks and results]

## Remaining Work
[What is left]

## Risks and Issues
[Problems or risks]

## Suggestions for Next Steps
[Recommendation]
```

### Atomic Write Rule
1. Write to .tmp first, then mv to .md
2. Relay only reads .md files

### Message Types You Can Send
- progress: partial work, more needed
- done: all complete (include verification)
- blocked: cannot proceed (MUST have reason + options)
- critique: feedback on Claude plan

### Rules
- Follow Claude instructions — do NOT replace the planner
- Do NOT modify Claude message files
- For every execute, report: completed, verification, remaining, risks
- If blocked, include reason and options
- If complete, include verification evidence
AGENTS_PROTOCOL

mkdir -p .codex
cp AGENTS.md .codex/instructions.md
info "Synced to .codex/instructions.md"

# ── 4. Claude Code slash commands ──
info "Creating .claude/commands/ ..."
mkdir -p .claude/commands

cat > .claude/commands/plan.md <<'CMD'
YOU MUST WRITE A FILE. Do NOT just reply in the terminal.

This command means: analyze the request, then write the plan as a FILE to
.cc-collab/queue/codex/. Your terminal reply should be SHORT — just confirm
the file was written.

Step 1 — Get the next sequence number:
Run this bash command:
  ls .cc-collab/queue/codex/ .cc-collab/queue/claude/ 2>/dev/null | grep -oP '^\d+' | sort -n | tail -1
If empty, start at 0001. Otherwise add 1 and zero-pad to 4 digits.

Step 2 — Write the plan file using bash. Example (adapt the content):

  cat > .cc-collab/queue/codex/0001-plan.md.tmp << 'MSGEOF'
  ---
  id: "0001"
  from: claude
  to: codex
  type: plan
  round: 1
  reply_to: null
  status: pending
  created_at: 2026-06-20T17:00:00+08:00
  ---
  ## Objective
  ...
  ## Acceptance Criteria
  ...
  ## Implementation Suggestions
  ...
  MSGEOF

  mv .cc-collab/queue/codex/0001-plan.md.tmp .cc-collab/queue/codex/0001-plan.md

Step 3 — Confirm:
Reply ONLY: "Plan #NNNN written to queue/codex/. Relay will dispatch to Codex."

RULES:
- Plan content goes IN THE FILE, not in your terminal response
- Use the bash tool to write the file
- If unsure, run: ls .cc-collab/queue/codex/ to verify

User request: $ARGUMENTS
CMD

cat > .claude/commands/next.md <<'CMD'
YOU MUST WRITE A FILE. Do NOT just reply in the terminal.

Step 1 — Find latest Codex message:
Run: ls -t .cc-collab/queue/claude/[0-9]*.md 2>/dev/null | head -1

Step 2 — Read that file completely.

Step 3 — Decide:
- progress + incomplete: write next execute to queue/codex/
- blocked: revise plan or emit needs_human to queue/codex/
- done: write done message to queue/codex/ and summarize
- critique: revise plan, write to queue/codex/

Step 4 — Write the response file using bash (.tmp then mv to .md).

Step 5 — Confirm:
Reply ONLY: "Message #NNNN [type] written. Relay will dispatch." plus ONE-LINE summary.

IMPORTANT: All content goes IN THE FILE. Terminal reply is just the confirmation.
CMD

cat > .claude/commands/review.md <<'CMD'
Read-only review — does NOT write a file.

Step 1: Run: ls -t .cc-collab/queue/claude/[0-9]*.md 2>/dev/null | head -1
Step 2: Read that file.
Step 3: Review against acceptance criteria (completeness, correctness, quality, security).
Step 4: Present verdict: PASS / NEEDS REVISION / FAIL.

To continue after review, use /next instead.
CMD

cat > .claude/commands/handoff.md <<'CMD'
YOU MUST WRITE A FILE. Do NOT just reply in the terminal.

Convert current conversation context into an execute message for Codex.

Step 1 — Get next sequence number (see /plan).
Step 2 — Use bash to write .cc-collab/queue/codex/NNNN-execute.md.tmp with:
  YAML frontmatter + Objective + Scope + Constraints + Acceptance Criteria + Implementation
Step 3 — mv .tmp to .md
Step 4 — Reply ONLY: "Handoff #NNNN written. Relay will dispatch."

Context: $ARGUMENTS
CMD

cat > .claude/commands/collab-status.md <<'CMD'
Check collaboration status:

1. Read .cc-collab/state/current.json (phase, round, mode, last message)
2. Count: queue/codex/*.md, queue/claude/*.md, archive count, ACK count
3. Show: tail -5 .cc-collab/logs/events.jsonl
4. Present as a clean summary.
CMD

# ── /adversarial-gate (relay auto-injects this before allowing done) ──
cat > .claude/commands/adversarial-gate.md <<'CMD'
ADVERSARIAL REVIEW GATE — relay triggered this because you said done.
Both reviews must pass before the task can truly finish.

Step 1: Run /adversarial-review on the current working tree (from codex-plugin-cc).
        Wait for the full output.

Step 2: Do your OWN independent critical review. Specifically look for:
        - Edge cases and missing error handling
        - Security vulnerabilities (injection, auth bypass, data leak)
        - Performance issues (N+1 queries, unbounded loops, memory leaks)
        - Missing input validation
        - Hardcoded values that should be configurable
        - Missing tests for critical paths
        - UX problems (confusing errors, missing feedback)

Step 3: Combine both review results. If EITHER review found issues:
        - Write an execute message to .cc-collab/queue/codex/ with ALL issues listed
        - Use bash (.tmp then mv)
        - Reply: "Adversarial review found issues. Fix message #NNNN sent."

Step 4: If BOTH reviews pass completely clean:
        - Write a done message to .cc-collab/queue/codex/
        - Include a summary of what was verified
        - Reply: "Adversarial review passed. Final done #NNNN sent."

IMPORTANT: Be genuinely critical. Do not rubber-stamp. The purpose of this gate
is to catch issues that were missed during normal collaboration.
CMD

# ── 5. codex-plugin-cc (adversarial review) ──
PLUGIN_DIR=".claude/plugins/codex-plugin-cc"
if [[ -d "$PLUGIN_DIR/plugins/codex/commands" ]]; then
    info "codex-plugin-cc already cloned"
else
    info "Cloning codex-plugin-cc for adversarial review ..."
    mkdir -p .claude/plugins
    if command -v git &>/dev/null; then
        git clone --depth 1 https://github.com/openai/codex-plugin-cc.git "$PLUGIN_DIR" 2>/dev/null || \
            info "Clone failed (network?). Adversarial review will not be available."
    else
        info "git not found, skipping codex-plugin-cc"
    fi
fi
# Symlink plugin commands into .claude/commands/ (works without plugin system)
if [[ -d "$PLUGIN_DIR/plugins/codex/commands" ]]; then
    for cmd_file in "$PLUGIN_DIR/plugins/codex/commands"/*.md; do
        [[ -e "$cmd_file" ]] || continue
        local_name=".claude/commands/$(basename "$cmd_file")"
        if [[ ! -e "$local_name" ]]; then
            ln -sf "$(realpath "$cmd_file")" "$local_name"
        fi
    done
    info "Linked codex-plugin-cc commands into .claude/commands/"
fi

# ── 6. .gitignore ──
IGNORE_ENTRY=".cc-collab/"
if [[ -f .gitignore ]]; then
    if ! grep -qF "$IGNORE_ENTRY" .gitignore; then
        info "Adding $IGNORE_ENTRY to .gitignore"
        printf '\n# Claude+Codex collab\n%s\n' "$IGNORE_ENTRY" >> .gitignore
    fi
else
    info "Creating .gitignore ..."
    printf '# Claude+Codex collab\n%s\n' "$IGNORE_ENTRY" > .gitignore
fi

# ── done ──
echo ""
info "Setup complete (v2)"
echo ""
echo -e "  ${C}/plan${R} <req>    Plan and send to Codex"
echo -e "  ${C}/next${R}          Read Codex result, decide next"
echo -e "  ${C}/review${R}        Review only (no auto-continue)"
echo -e "  ${C}/handoff${R} <ctx> Convert conversation to Codex task"
echo -e "  ${C}/collab-status${R} Show queue and state"
echo ""
echo -e "  Next: ${B}bash /path/to/cc-collab-v2/start.sh${R}"
echo ""
