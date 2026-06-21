#!/usr/bin/env bash
#
# relay.sh — Claude Code + Codex CLI 协作中继 (v2 完整版)
#
# 职责:
#   1. 扫描消息队列
#   2. 去重 (ACK)
#   3. 轮次控制 + 状态机
#   4. 选择目标 pane
#   5. 注入短触发命令
#   6. 记录事件日志
#
# 不做的事:
#   - 不改写消息内容
#   - 不把长 prompt 塞进 pane
#   - 不擅自判断方案优劣
#
# 依赖: bash 4+, tmux, jq
#

set -euo pipefail

# ═══════════════════════════════════════════════════════════════
# 配置
# ═══════════════════════════════════════════════════════════════
COLLAB_DIR="${CC_COLLAB_DIR:-./.cc-collab}"
TMUX_SESSION="${CC_TMUX_SESSION:-cc-collab}"
POLL_INTERVAL="${CC_POLL_INTERVAL:-3}"

# 自动停止阈值
MAX_ROUNDS="${CC_MAX_ROUNDS:-20}"
MAX_IDLE_SECONDS="${CC_MAX_IDLE:-900}"
MAX_CONSECUTIVE_EMPTY="${CC_MAX_EMPTY:-9999}"
MAX_CONSECUTIVE_BLOCKED="${CC_MAX_BLOCKED:-3}"
MAX_TYPE_REPEAT="${CC_MAX_TYPE_REPEAT:-6}"
MIN_INJECT_INTERVAL="${CC_MIN_INJECT_INTERVAL:-8}"

# 路径
QUEUE_CLAUDE="$COLLAB_DIR/queue/claude"
QUEUE_CODEX="$COLLAB_DIR/queue/codex"
ARCHIVE_DIR="$COLLAB_DIR/archive"
STATE_DIR="$COLLAB_DIR/state"
LOGS_DIR="$COLLAB_DIR/logs"
RUNTIME_DIR="$COLLAB_DIR/runtime"

STATE_FILE="$STATE_DIR/current.json"
LOCK_DIR="$STATE_DIR/relay.lock"
RELAY_LOG="$LOGS_DIR/relay.log"
EVENTS_LOG="$LOGS_DIR/events.jsonl"

# tmux pane 标识 — 优先从 runtime/ 读取 start.sh 写入的实际 pane ID
# 回退到索引号（手动搭建时需要自己确认编号）
CLAUDE_PANE="$(cat "$RUNTIME_DIR/claude-pane" 2>/dev/null || echo "${TMUX_SESSION}:0.0")"
CODEX_PANE="$(cat "$RUNTIME_DIR/codex-pane" 2>/dev/null || echo "${TMUX_SESSION}:0.1")"

# ═══════════════════════════════════════════════════════════════
# 颜色
# ═══════════════════════════════════════════════════════════════
readonly C_CYAN='\033[0;36m'
readonly C_YELLOW='\033[0;33m'
readonly C_GREEN='\033[0;32m'
readonly C_RED='\033[0;31m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_RESET='\033[0m'

# ═══════════════════════════════════════════════════════════════
# 工具函数
# ═══════════════════════════════════════════════════════════════
ts_iso()   { date +"%Y-%m-%dT%H:%M:%S%z"; }
ts_short() { date +"%H:%M:%S"; }
epoch_now(){ date +%s; }

log_relay() {
    local msg="$1"
    echo -e "${C_GREEN}[$(ts_short)] [relay]${C_RESET} $msg"
    echo "[$(ts_iso)] $msg" >> "$RELAY_LOG" 2>/dev/null || true
}

log_event() {
    # log_event "event_name" "k1" "v1" "k2" "v2" ...
    local event="$1"; shift
    local json="{\"ts\":\"$(ts_iso)\",\"event\":\"${event}\""
    while [[ $# -ge 2 ]]; do
        # 转义双引号
        local val="${2//\"/\\\"}"
        json+=",\"$1\":\"$val\""
        shift 2
    done
    json+="}"
    echo "$json" >> "$EVENTS_LOG" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# 锁管理 (mkdir 原子锁 + PID 检测过期)
# ═══════════════════════════════════════════════════════════════
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        echo $$ > "$LOCK_DIR/pid"
        echo "$(epoch_now)" > "$LOCK_DIR/acquired_at"
        return 0
    fi
    # 检查是否为过期锁
    local lock_pid
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
        log_relay "清理过期锁 (PID $lock_pid 已不存在)"
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            echo "$(epoch_now)" > "$LOCK_DIR/acquired_at"
            return 0
        fi
    fi
    return 1
}

release_lock() {
    if [[ -d "$LOCK_DIR" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
        # 只释放自己持有的锁
        if [[ "$lock_pid" == "$$" ]]; then
            rm -rf "$LOCK_DIR"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════
# 状态管理 (current.json + jq)
# ═══════════════════════════════════════════════════════════════
init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" <<'SJSON'
{
  "phase": "idle",
  "round": 0,
  "last_msg_id": null,
  "last_msg_type": null,
  "consecutive_empty": 0,
  "consecutive_blocked": 0,
  "type_counts": {},
  "last_activity_epoch": 0,
  "started_at": null,
  "mode": "auto",
  "adversarial_reviewed": false,
  "stop_reason": ""
}
SJSON
    fi
}

# 读取状态字段
get_state() {
    jq -r ".${1} // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

# 写入单个状态字段 (自动检测数值 / 布尔 / null / 字符串)
set_state() {
    local key="$1" val="$2"
    local tmp="${STATE_FILE}.tmp.$$"
    if [[ "$val" =~ ^-?[0-9]+$ ]] || [[ "$val" == "null" ]] || [[ "$val" == "true" ]] || [[ "$val" == "false" ]]; then
        jq ".${key} = ${val}" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    else
        jq ".${key} = \"${val}\"" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi
}

# 根据消息内容批量更新状态
update_state_for_message() {
    local msg_id="$1" msg_type="$2" msg_from="$3"
    local tmp="${STATE_FILE}.tmp.$$"

    # 消息类型 → 阶段映射
    # 关键: 只有 Claude 的 done 才算全局完成
    # Codex 的 done 只代表"当前步骤完成"，等同 reviewing
    local new_phase
    case "$msg_type" in
        plan)        new_phase="planning" ;;
        critique)    new_phase="critique" ;;
        execute)     new_phase="executing" ;;
        progress)    new_phase="executing" ;;
        review)      new_phase="reviewing" ;;
        blocked)     new_phase="blocked" ;;
        done)
            if [[ "$msg_from" == "claude" ]]; then
                local ar_flag
                ar_flag=$(jq -r '.adversarial_reviewed // false' "$STATE_FILE" 2>/dev/null)
                if [[ "$ar_flag" == "true" ]]; then
                    new_phase="done"
                else
                    new_phase="adversarial_review"
                fi
            else
                new_phase="reviewing"
            fi
            ;;
        needs_human) new_phase="blocked" ;;  # mode 由 enter_manual_override 设置，phase 保持可恢复
        *)           new_phase=$(get_state phase) ;;
    esac

    # 当 Claude 发出 plan 或 execute 时轮次 +1，并重置对抗审查标记
    local round
    round=$(get_state round)
    if [[ "$msg_from" == "claude" ]] && [[ "$msg_type" == "plan" || "$msg_type" == "execute" ]]; then
        round=$((round + 1))
        # 有新工作 → 之前的对抗审查作废，完成后要重新审查
        local ar_tmp="${STATE_FILE}.tmp.ar.$$"
        jq '.adversarial_reviewed = false' "$STATE_FILE" > "$ar_tmp" && mv "$ar_tmp" "$STATE_FILE"
    fi

    # 连续 blocked 计数
    local con_blocked
    con_blocked=$(get_state consecutive_blocked)
    if [[ "$msg_type" == "blocked" ]]; then
        con_blocked=$((con_blocked + 1))
    else
        con_blocked=0
    fi

    # 同类型消息计数
    local type_count
    type_count=$(jq -r ".type_counts.\"${msg_type}\" // 0" "$STATE_FILE")
    type_count=$((type_count + 1))

    jq \
        --arg      phase       "$new_phase" \
        --arg      msg_id      "$msg_id" \
        --arg      msg_type    "$msg_type" \
        --argjson  round       "$round" \
        --argjson  con_blocked "$con_blocked" \
        --argjson  type_count  "$type_count" \
        --argjson  now         "$(epoch_now)" \
        '
        .phase              = $phase        |
        .round              = $round        |
        .last_msg_id        = $msg_id       |
        .last_msg_type      = $msg_type     |
        .consecutive_blocked= $con_blocked  |
        .consecutive_empty  = 0             |
        .type_counts[$msg_type] = $type_count |
        .last_activity_epoch= $now
        ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    log_event "state_updated" \
        "phase" "$new_phase" "round" "$round" \
        "msg_id" "$msg_id" "msg_type" "$msg_type"
}

# ═══════════════════════════════════════════════════════════════
# 队列管理
# ═══════════════════════════════════════════════════════════════

# 返回指定队列中第一条未 ACK 的正式消息路径 (不含 .tmp)
find_next_message() {
    local queue_dir="$1"
    local target="$2"    # claude | codex
    local f
    for f in "$queue_dir"/[0-9]*.md; do
        [[ -e "$f" ]] || return 1
        # 跳过临时文件
        [[ "$f" == *.tmp.md ]] && continue
        [[ "$f" == *.tmp ]]    && continue
        local msg_id
        msg_id=$(basename "$f" | grep -oP '^\d+' || echo "")
        [[ -z "$msg_id" ]] && continue
        if ! is_acked "$msg_id" "$target"; then
            echo "$f"
            return 0
        fi
    done
    return 1
}

# 从 frontmatter 提取字段；回退到文件名推断
extract_field() {
    local file="$1" field="$2"
    local val
    val=$(sed -n '/^---$/,/^---$/{ /^'"$field"':/{ s/^'"$field"':[[:space:]]*//; s/^["'"'"']//; s/["'"'"']$//; p; q; } }' "$file" 2>/dev/null || echo "")
    echo "$val"
}

extract_id() {
    local file="$1"
    local val
    val=$(extract_field "$file" "id")
    if [[ -z "$val" ]]; then
        val=$(basename "$file" | grep -oP '^\d+' || echo "0000")
    fi
    echo "$val"
}

extract_type() {
    local file="$1"
    local val
    val=$(extract_field "$file" "type")
    if [[ -z "$val" ]]; then
        val=$(basename "$file" .md | sed 's/^[0-9]*-//')
    fi
    echo "$val"
}

extract_from() {
    local file="$1"
    extract_field "$file" "from"
}

# ═══════════════════════════════════════════════════════════════
# ACK 管理
# ═══════════════════════════════════════════════════════════════
is_acked() {
    [[ -f "$STATE_DIR/ack-${1}-${2}" ]]
}

create_ack() {
    echo "$(ts_iso)" > "$STATE_DIR/ack-${1}-${2}"
    log_event "ack_created" "msg_id" "$1" "target" "$2"
}

# ═══════════════════════════════════════════════════════════════
# Pane 管理
# ═══════════════════════════════════════════════════════════════
get_pane_id() {
    case "$1" in
        claude) echo "$CLAUDE_PANE" ;;
        codex)  echo "$CODEX_PANE" ;;
    esac
}

check_pane_exists() {
    tmux list-panes -t "$1" &>/dev/null
}

check_pane_ready() {
    local target="$1"
    local pane
    pane=$(get_pane_id "$target")

    # 1) pane 必须存在
    if ! check_pane_exists "$pane"; then
        log_relay "${C_RED}pane '${target}' 不存在${C_RESET}"
        log_event "pane_check" "target" "$target" "status" "not_found"
        return 1
    fi

    # 2) 距上次注入必须超过冷却时间
    local last_file="$RUNTIME_DIR/last_inject_${target}"
    if [[ -f "$last_file" ]]; then
        local last_epoch now_epoch elapsed
        last_epoch=$(cat "$last_file")
        now_epoch=$(epoch_now)
        elapsed=$((now_epoch - last_epoch))
        if [[ $elapsed -lt $MIN_INJECT_INTERVAL ]]; then
            log_event "pane_check" "target" "$target" "status" "cooldown" "remaining" "$((MIN_INJECT_INTERVAL - elapsed))"
            return 1
        fi
    fi

    log_event "pane_check" "target" "$target" "status" "ready"
    return 0
}

record_inject_time() {
    echo "$(epoch_now)" > "$RUNTIME_DIR/last_inject_${1}"
}

# ═══════════════════════════════════════════════════════════════
# 短命令构建 + 注入
# ═══════════════════════════════════════════════════════════════

build_inject_command() {
    local msg_file="$1" target="$2" msg_type="$3"

    # 使用相对路径让命令更短
    local rel_path
    rel_path=$(realpath --relative-to="$(pwd)" "$msg_file" 2>/dev/null || echo "$msg_file")

    case "$target" in
        codex)
            # Codex 侧: 读消息 → 按 AGENTS.md 协议执行 → 写结果到 queue/claude/
            echo "New task: read ${rel_path} and follow your AGENTS.md protocol."
            ;;
        claude)
            # Claude 侧: 用 /next 自定义命令自动读取最新消息并处理
            echo "/next"
            ;;
    esac
}

inject_to_pane() {
    local target="$1" command="$2"
    local pane
    pane=$(get_pane_id "$target")

    if [[ "$target" == "codex" ]]; then
        # Codex TUI 需要先接收文本再按回车，分两步发送
        tmux send-keys -t "$pane" "$command"
        sleep 2
        tmux send-keys -t "$pane" Enter
        # 再等一下发第二个回车，确认 Codex 的 approval prompt
        sleep 3
        tmux send-keys -t "$pane" Enter
    else
        tmux send-keys -t "$pane" "$command" Enter
    fi
    record_inject_time "$target"

    log_event "inject" "target" "$target" "command" "$command"
}

# ═══════════════════════════════════════════════════════════════
# 自动停止判断
# ═══════════════════════════════════════════════════════════════

# 返回 0 (应停止) 并输出原因，或返回 1 (继续)
should_auto_stop() {
    local phase round con_empty con_blocked last_type type_count last_act now idle

    phase=$(get_state phase)

    # 已完成
    if [[ "$phase" == "done" ]]; then
        echo "任务已完成 (phase=done)"
        return 0
    fi

    # 最大轮数
    round=$(get_state round)
    if [[ "$round" -ge "$MAX_ROUNDS" ]]; then
        echo "达到最大轮数 (${round} >= ${MAX_ROUNDS})"
        return 0
    fi

    # 连续空轮询
    con_empty=$(get_state consecutive_empty)
    if [[ "$con_empty" -ge "$MAX_CONSECUTIVE_EMPTY" ]]; then
        echo "连续 ${con_empty} 次轮询无新消息"
        return 0
    fi

    # 连续阻塞
    con_blocked=$(get_state consecutive_blocked)
    if [[ "$con_blocked" -ge "$MAX_CONSECUTIVE_BLOCKED" ]]; then
        echo "连续 ${con_blocked} 次阻塞"
        return 0
    fi

    # 同类消息重复
    last_type=$(get_state last_msg_type)
    if [[ -n "$last_type" && "$last_type" != "null" ]]; then
        type_count=$(jq -r ".type_counts.\"${last_type}\" // 0" "$STATE_FILE" 2>/dev/null || echo 0)
        if [[ "$type_count" -ge "$MAX_TYPE_REPEAT" ]]; then
            echo "消息类型 '${last_type}' 连续出现 ${type_count} 次"
            return 0
        fi
    fi

    # 空闲超时
    last_act=$(get_state last_activity_epoch)
    if [[ -n "$last_act" && "$last_act" != "0" && "$last_act" != "null" ]]; then
        now=$(epoch_now)
        idle=$((now - last_act))
        if [[ $idle -ge $MAX_IDLE_SECONDS ]]; then
            echo "空闲超时 (${idle}s >= ${MAX_IDLE_SECONDS}s)"
            return 0
        fi
    fi

    return 1
}

enter_manual_override() {
    local reason="$1"
    set_state mode "manual_override"
    set_state stop_reason "$reason"
    log_relay ""
    log_relay "${C_RED}${C_BOLD}══ 自动暂停 ══${C_RESET}"
    log_relay "${C_RED}原因: ${reason}${C_RESET}"
    log_relay "${C_YELLOW}有新消息时会自动恢复 (needs_human 除外)${C_RESET}"
    log_relay ""
    log_event "auto_stop" "reason" "$reason"
}

is_manual_override() {
    [[ "$(get_state mode)" == "manual_override" ]]
}

do_resume() {
    local reason="$1"
    set_state mode "auto"
    set_state phase "idle"
    set_state consecutive_empty 0
    set_state consecutive_blocked 0
    local tmp="${STATE_FILE}.tmp.$$"
    jq '.type_counts = {} | .adversarial_reviewed = false' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    set_state last_activity_epoch "$(epoch_now)"
    log_relay "${C_GREEN}${C_BOLD}已恢复自动模式${C_RESET} ($reason)"
    log_event "resumed" "reason" "$reason"
}

check_resume() {
    # 方式 1: 手动 touch resume 文件
    if [[ -f "$STATE_DIR/resume" ]]; then
        rm -f "$STATE_DIR/resume"
        do_resume "手动恢复"
        return 0
    fi

    # 方式 2: 自动恢复 — 队列中有新消息时自动恢复 (needs_human 除外)
    local stop_reason
    stop_reason=$(jq -r '.stop_reason // ""' "$STATE_FILE" 2>/dev/null)
    if [[ "$stop_reason" == *"needs_human"* ]]; then
        return 1  # needs_human 必须手动恢复
    fi

    # 检查队列中是否有未 ACK 的新消息
    if find_next_message "$QUEUE_CODEX" "codex" &>/dev/null || \
       find_next_message "$QUEUE_CLAUDE" "claude" &>/dev/null; then
        do_resume "检测到新消息，自动恢复"
        return 0
    fi

    return 1
}

# ═══════════════════════════════════════════════════════════════
# 消息处理核心
# ═══════════════════════════════════════════════════════════════
process_message() {
    local msg_file="$1" target="$2"

    local msg_id msg_type msg_from
    msg_id=$(extract_id "$msg_file")
    msg_type=$(extract_type "$msg_file")
    msg_from=$(extract_from "$msg_file")

    # 回退推断 from
    if [[ -z "$msg_from" ]]; then
        if [[ "$target" == "claude" ]]; then msg_from="codex"
        else msg_from="claude"; fi
    fi

    log_relay "${C_BOLD}消息 #${msg_id}${C_RESET} [${msg_type}] ${msg_from} → ${target}"

    # ── done/review/needs_human 消息不需要派发给 Codex 执行 ──
    if [[ "$target" == "codex" ]] && [[ "$msg_type" == "done" || "$msg_type" == "review" || "$msg_type" == "needs_human" ]]; then
        log_relay "${C_DIM}  跳过派发 (${msg_type} 类型不需要 Codex 执行)${C_RESET}"
        create_ack "$msg_id" "$target"
        update_state_for_message "$msg_id" "$msg_type" "$msg_from"
        return 0
    fi

    # ── 检查 pane 就绪 ──
    if ! check_pane_ready "$target"; then
        log_relay "${C_YELLOW}  目标 pane '${target}' 未就绪，下轮重试${C_RESET}"
        return 1
    fi

    # ── 构建 & 注入短命令 ──
    local cmd
    cmd=$(build_inject_command "$msg_file" "$target" "$msg_type")
    log_relay "  → ${target}: ${C_DIM}${cmd}${C_RESET}"
    inject_to_pane "$target" "$cmd"

    # ── 创建 ACK ──
    create_ack "$msg_id" "$target"

    # ── 更新状态机 ──
    update_state_for_message "$msg_id" "$msg_type" "$msg_from"

    # ── needs_human 触发手动模式（但 phase 保持可恢复） ──
    if [[ "$msg_type" == "needs_human" ]]; then
        enter_manual_override "收到 needs_human 消息 (#${msg_id})"
    fi

    # ── 归档副本 ──
    local session_tag
    session_tag=$(date +%Y%m%d)
    local round
    round=$(get_state round)
    local archive_session="$ARCHIVE_DIR/${session_tag}-r${round}"
    mkdir -p "$archive_session"
    cp "$msg_file" "$archive_session/" 2>/dev/null || true

    log_event "dispatched" \
        "msg_id" "$msg_id" "from" "$msg_from" "to" "$target" \
        "type" "$msg_type" "round" "$round"

    return 0
}

# ═══════════════════════════════════════════════════════════════
# 帮助信息
# ═══════════════════════════════════════════════════════════════
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

Claude Code + Codex CLI 协作中继 (v2)

选项:
  --help, -h         显示帮助
  --status           打印当前状态后退出
  --reset            重置状态后退出 (不删除消息)

环境变量:
  CC_COLLAB_DIR          通信目录        (默认 ./.cc-collab)
  CC_TMUX_SESSION        tmux 会话名     (默认 cc-collab)
  CC_POLL_INTERVAL       轮询间隔秒数    (默认 3)
  CC_MAX_ROUNDS          最大轮数        (默认 10)
  CC_MAX_IDLE            空闲超时秒数    (默认 300)
  CC_MAX_EMPTY           最大连续空轮询  (默认 15)
  CC_MAX_BLOCKED         最大连续阻塞    (默认 2)
  CC_MAX_TYPE_REPEAT     同类消息重复上限(默认 4)
  CC_MIN_INJECT_INTERVAL 注入冷却秒数    (默认 8)
EOF
    exit 0
}

print_status() {
    echo ""
    echo -e "${C_GREEN}═══ Relay 状态 ═══${C_RESET}"
    if [[ -f "$STATE_FILE" ]]; then
        jq '.' "$STATE_FILE"
    else
        echo "(未初始化)"
    fi
    echo ""
    echo -e "${C_GREEN}═══ 队列 ═══${C_RESET}"
    echo -n "  → Codex (queue/codex):  "
    find "$QUEUE_CODEX" -name '[0-9]*.md' ! -name '*.tmp*' 2>/dev/null | wc -l | tr -d ' '
    echo -n "  → Claude (queue/claude): "
    find "$QUEUE_CLAUDE" -name '[0-9]*.md' ! -name '*.tmp*' 2>/dev/null | wc -l | tr -d ' '
    echo ""
    echo -e "${C_GREEN}═══ ACK ═══${C_RESET}"
    ls "$STATE_DIR"/ack-* 2>/dev/null | wc -l | xargs -I{} echo "  已确认消息: {}"
    echo ""
    exit 0
}

reset_state() {
    log_relay "重置状态..."
    # 归档队列中的旧消息（防止重启后重发）
    local archive_tag
    archive_tag="$ARCHIVE_DIR/$(date +%Y%m%d-%H%M%S)"
    local has_old=false
    for q in "$QUEUE_CODEX" "$QUEUE_CLAUDE"; do
        for f in "$q"/[0-9]*.md; do
            [[ -e "$f" ]] || continue
            has_old=true
            mkdir -p "$archive_tag"
            mv "$f" "$archive_tag/"
        done
    done
    if $has_old; then
        log_relay "旧消息已归档到 $archive_tag"
    fi
    # 清理状态
    rm -f "$STATE_FILE" "$STATE_DIR"/ack-* "$RUNTIME_DIR"/last_inject_*
    rm -rf "$LOCK_DIR"
    init_state
    log_relay "状态已重置，队列已清空"
    exit 0
}

# ═══════════════════════════════════════════════════════════════
# 依赖检查
# ═══════════════════════════════════════════════════════════════
check_deps() {
    local missing=()
    command -v tmux &>/dev/null || missing+=("tmux")
    command -v jq   &>/dev/null || missing+=("jq")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "错误: 缺少依赖: ${missing[*]}"
        echo "  Ubuntu: sudo apt install ${missing[*]}"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════
# 主循环
# ═══════════════════════════════════════════════════════════════
main() {
    # 参数处理
    case "${1:-}" in
        --help|-h) usage ;;
        --status)  print_status ;;
        --reset)   reset_state ;;
    esac

    check_deps

    # 初始化目录和状态
    mkdir -p "$QUEUE_CLAUDE" "$QUEUE_CODEX" "$ARCHIVE_DIR" \
             "$STATE_DIR" "$LOGS_DIR" "$RUNTIME_DIR"
    init_state
    touch "$RELAY_LOG" "$EVENTS_LOG"

    # 记录启动时间
    if [[ "$(get_state started_at)" == "null" || -z "$(get_state started_at)" ]]; then
        set_state started_at "$(ts_iso)"
    fi
    set_state last_activity_epoch "$(epoch_now)"

    # Banner
    echo ""
    echo -e "${C_GREEN}════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_GREEN}  CC-COLLAB Relay v2${C_RESET}"
    echo -e "${C_GREEN}════════════════════════════════════════════════════${C_RESET}"
    echo -e "  通信目录:   ${C_DIM}${COLLAB_DIR}${C_RESET}"
    echo -e "  tmux 会话:  ${C_DIM}${TMUX_SESSION}${C_RESET}"
    echo -e "  最大轮数:   ${C_DIM}${MAX_ROUNDS}${C_RESET}"
    echo -e "  空闲超时:   ${C_DIM}${MAX_IDLE_SECONDS}s${C_RESET}"
    echo -e "  注入冷却:   ${C_DIM}${MIN_INJECT_INTERVAL}s${C_RESET}"
    echo -e "  轮询间隔:   ${C_DIM}${POLL_INTERVAL}s${C_RESET}"
    echo -e "${C_GREEN}════════════════════════════════════════════════════${C_RESET}"
    echo ""
    log_relay "relay 已启动，等待消息..."
    log_event "relay_started"
    echo ""

    # ── 主循环 ──
    while true; do

        # 手动模式: 只检查 resume 信号
        if is_manual_override; then
            check_resume || true
            sleep "$POLL_INTERVAL"
            continue
        fi

        # 自动停止检查
        local stop_reason
        if stop_reason=$(should_auto_stop); then
            enter_manual_override "$stop_reason"
            continue
        fi

        # ── 对抗审查门控 ──
        local current_phase
        current_phase=$(get_state phase)
        if [[ "$current_phase" == "adversarial_review" ]]; then
            local ar_injected
            ar_injected=$(jq -r '.adversarial_reviewed // false' "$STATE_FILE" 2>/dev/null)
            if [[ "$ar_injected" != "true" ]] && check_pane_ready "claude"; then
                log_relay ""
                log_relay "${C_BOLD}${C_YELLOW}══ 对抗审查门控 ══${C_RESET}"
                log_relay "${C_YELLOW}Claude 认为已完成，但必须通过对抗审查才能结项${C_RESET}"
                inject_to_pane "claude" "/adversarial-gate run"
                local ar_tmp="${STATE_FILE}.tmp.ar2.$$"
                jq '.adversarial_reviewed = true' "$STATE_FILE" > "$ar_tmp" && mv "$ar_tmp" "$STATE_FILE"
                set_state last_activity_epoch "$(epoch_now)"
                log_event "adversarial_review_triggered"
                sleep "$POLL_INTERVAL"
                continue
            fi
            # 审查已触发，等待 Claude 写新消息（execute 或 done）
            # 不做额外操作，正常扫描队列
        fi

        # 获取锁
        if ! acquire_lock; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        local processed=false

        # ── 扫描发给 Codex 的消息 (Claude → Codex) ──
        local codex_msg=""
        if codex_msg=$(find_next_message "$QUEUE_CODEX" "codex"); then
            if process_message "$codex_msg" "codex"; then
                processed=true
            fi
        fi

        # ── 扫描发给 Claude 的消息 (Codex → Claude) ──
        local claude_msg=""
        if claude_msg=$(find_next_message "$QUEUE_CLAUDE" "claude"); then
            if process_message "$claude_msg" "claude"; then
                processed=true
            fi
        fi

        # ─�── 更新空轮计数 ──
        if $processed; then
            set_state consecutive_empty 0
            set_state last_activity_epoch "$(epoch_now)"
        else
            local ce
            ce=$(get_state consecutive_empty)
            ce=$((ce + 1))
            set_state consecutive_empty "$ce"
        fi

        release_lock
        sleep "$POLL_INTERVAL"
    done
}

cleanup() {
    release_lock
    log_relay "relay stopped"
    log_event "relay_stopped"
    exit 0
}
trap cleanup INT TERM

main "$@"
ERM

main "$@"
 release_lock
        sleep "$POLL_INTERVAL"
    done
}

# 退出清理
cleanup() {
    release_lock
    log_relay "relay 已停止"
    log_event "relay_stopped"
    exit 0
}
trap cleanup INT TERM

main "$@"
