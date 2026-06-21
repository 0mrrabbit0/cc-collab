<p align="center">
  <h1 align="center">CC-Collab v2</h1>
  <p align="center">
    <strong>Claude Code × Codex CLI — AI 双智能体协作框架</strong>
  </p>
  <p align="center">
    让两个 AI 在各自的交互式终端中，通过消息队列自动接力协作完成软件工程任务
  </p>
  <p align="center">
    <a href="#快速开始">快速开始</a> •
    <a href="#系统架构">系统架构</a> •
    <a href="#使用指南">使用指南</a> •
    <a href="#配置参考">配置参考</a> •
    <a href="#故障排查">故障排查</a>
  </p>
</p>

---

## 项目简介

CC-Collab v2 是一个轻量级的 AI 协作编排框架，让 **Claude Code**（Anthropic）和 **Codex CLI**（OpenAI）在同一个 tmux 会话中自主协作完成软件开发任务。

**Claude** 担任 **规划者与审查者** — 负责需求分析、方案设计、代码审查和质量把关。**Codex** 担任 **执行者** — 负责代码实现、测试运行和进度汇报。**Relay 中继守护进程** 负责桥接双方：扫描文件消息队列、通过 `tmux send-keys` 派发短触发命令、通过状态机管理协作生命周期。

### 核心特性

- **基于文件的消息协议** — 所有通信通过带 YAML frontmatter 的 Markdown 文件完成，不注入长文本到终端
- **原子写入** — 消息先写 `.tmp` 再 rename，防止读到半成品
- **状态机 + 自动停止** — 跟踪轮次、空闲时间、阻塞状态、连续空轮询等指标
- **ACK 去重** — 每条消息对每个目标只派发一次
- **注入冷却** — 防止打断正在处理中的 AI（默认间隔 8 秒）
- **对抗审查门控** — 任务标记完成前，必须通过独立的对抗性审查
- **随时人工接管** — 你可以在任意时刻直接在 AI 窗口输入指令；安全阈值触发时 Relay 自动暂停
- **完整审计轨迹** — 结构化 JSONL 事件日志 + 可读中继日志 + 消息归档

---

## 系统架构

```
┌──────────────────────────┐                              ┌──────────────────────────┐
│      Claude Code         │    .cc-collab/queue/codex/    │       Codex CLI          │
│                          │  ──────────────────────────►  │                          │
│  • 需求分析              │                              │  • 代码实现              │
│  • 方案规划              │    .cc-collab/queue/claude/   │  • 测试执行              │
│  • 代码审查              │  ◄──────────────────────────  │  • 进度汇报              │
│  • 质量把关              │                              │  • 阻塞上报              │
└────────────┬─────────────┘                              └────────────┬─────────────┘
             │                                                         │
             │              ┌──────────────────────┐                   │
             └──────────────│    Relay 中继守护进程  │───────────────────┘
                            │                      │
                            │  • 队列扫描          │
                            │  • ACK 去重          │
                            │  • 状态机管理        │
                            │  • 短命令注入        │
                            │  • 自动停止逻辑      │
                            │  • 事件日志记录      │
                            └──────────────────────┘
```

### 工作流程

1. 你在 Claude 窗口输入 `/plan <需求描述>`
2. Claude 分析需求，将方案文件写入 `.cc-collab/queue/codex/`
3. Relay 检测到新文件，向 Codex 窗口注入一条短触发命令
4. Codex 读取方案文件，执行任务，将结果写入 `.cc-collab/queue/claude/`
5. Relay 检测到结果，向 Claude 窗口注入 `/next`
6. Claude 审查执行结果，决定下一步动作（继续迭代或标记完成）
7. 循环重复，直到任务完成或自动停止条件触发

---

## 前置准备

### 依赖工具

| 依赖 | 版本要求 | 安装方式 |
|:-----|:---------|:---------|
| **Bash** | 4.0+ | Linux/macOS 系统自带 |
| **tmux** | 2.0+ | `sudo apt install tmux`（Ubuntu/WSL）或 `brew install tmux`（macOS） |
| **jq** | 1.5+ | `sudo apt install jq`（Ubuntu/WSL）或 `brew install jq`（macOS） |
| **git** | 2.0+ | `sudo apt install git`（Ubuntu/WSL）或 `brew install git`（macOS） |
| **Claude Code** | 最新版 | `npm i -g @anthropic-ai/claude-code` |
| **Codex CLI** | 最新版 | `npm i -g @openai/codex` |

### codex-plugin-cc（对抗审查插件）

[codex-plugin-cc](https://github.com/openai/codex-plugin-cc) 是 OpenAI 官方提供的 Codex 插件集，CC-Collab 使用其中的**对抗审查（adversarial review）**命令来实现完成前的质量门控。

`setup.sh` 会在初始化时自动克隆该仓库到 `.claude/plugins/codex-plugin-cc`，并将其命令符号链接到 `.claude/commands/` 目录下。

**前置要求：**

- 需要 `git` 已安装
- 需要能访问 GitHub（用于 `git clone`）
- 如果网络不通，setup 会跳过此步骤，对抗审查功能将不可用（不影响其他功能）

**手动安装（如果自动克隆失败）：**

```bash
cd ~/your-project
mkdir -p .claude/plugins
git clone --depth 1 https://github.com/openai/codex-plugin-cc.git .claude/plugins/codex-plugin-cc

# 将插件命令链接到 Claude Code 的命令目录
for f in .claude/plugins/codex-plugin-cc/plugins/codex/commands/*.md; do
    ln -sf "$(realpath "$f")" ".claude/commands/$(basename "$f")"
done
```

### 环境验证

```bash
# 逐项确认所有依赖已安装
claude --version        # Claude Code CLI
codex --version         # Codex CLI
tmux -V                 # tmux 终端复用器
jq --version            # JSON 处理器
git --version           # Git（用于克隆对抗审查插件）

# WSL2 用户：确认 UTF-8 编码
echo $LANG              # 应包含 UTF-8
# 如果不是：
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
# 建议写入 ~/.bashrc 永久生效
```

### API 密钥

两个 AI CLI 工具都需要各自的 API 密钥：

- **Claude Code**：需要 Anthropic API Key 或有效的 Claude 订阅
- **Codex CLI**：需要 OpenAI API Key

请参考各工具的官方文档完成认证配置。

---

## 快速开始

### 第一步：安装工具包

```bash
# 克隆或复制到一个固定位置（所有项目共用）
mkdir -p ~/tools
cp -r cc-collab-v2 ~/tools/cc-collab-v2
chmod +x ~/tools/cc-collab-v2/*.sh

# 验证
ls ~/tools/cc-collab-v2/
# 预期输出: relay.sh  setup.sh  start.sh  README.md  WALKTHROUGH.md
```

### 第二步：在项目中初始化

```bash
cd ~/your-project        # 替换为你的实际项目路径
bash ~/tools/cc-collab-v2/setup.sh
```

初始化完成后会创建：

- `.cc-collab/` — 通信目录（队列、状态、日志）
- `CLAUDE.md` — 追加 Claude 协作协议（不覆盖已有内容）
- `AGENTS.md` — Codex 协作协议
- `.claude/commands/` — 快捷命令（`/plan`、`/next`、`/review`、`/handoff`、`/collab-status`）
- `.gitignore` — 自动排除 `.cc-collab/`

### 第三步：启动协作会话

```bash
bash ~/tools/cc-collab-v2/start.sh
```

屏幕切换到 tmux，出现三栏布局：

```
┌────────────────────────┬────────────────────────┐
│     Claude Code        │       Codex CLI         │
│     (交互式终端)        │     (交互式终端)         │
├────────────────────────┴────────────────────────┤
│              Relay 中继守护进程 (自动运行)         │
└─────────────────────────────────────────────────┘
```

等待 3-5 秒，三个面板各自初始化完成后即可开始。

### 第四步：发起任务

在 **Claude 窗口**（左上）输入：

```
/plan 实现一个 REST API，包含用户注册、登录和 JWT 鉴权
```

协作循环自动启动。你可以同时观察三个窗口的实时输出。

---

## 使用指南

### 快捷命令

| 命令 | 说明 |
|:-----|:-----|
| `/plan <需求>` | 分析需求，将方案写入 `queue/codex/` |
| `/next` | 读取 Codex 最新结果，自动决定下一步动作 |
| `/review` | 审查最新结果，但不自动继续（等你决定） |
| `/handoff <上下文>` | 将当前对话上下文转为 Codex 的执行任务 |
| `/collab-status` | 显示队列状态、状态机和最近事件 |

### 典型工作流

#### 标准流程：规划 → 执行 → 审查

```
你:     /plan 添加健康检查接口 GET /healthz，返回 JSON 格式的服务状态
Claude: [分析需求] → 写 0001-plan.md → queue/codex/
Relay:  检测到 0001 → 向 Codex 注入触发命令
Codex:  [读取方案，执行实现] → 写 0002-progress.md → queue/claude/
Relay:  检测到 0002 → 向 Claude 注入 /next
Claude: [审查结果] → 满意 → 写 0003-done.md
Relay:  phase=done → 自动停止
```

#### 多轮架构评审

```
你:     /plan 设计高并发订单处理系统（只做架构分析，不实施）
Claude: 写 0001-plan.md (type: plan)
Codex:  读取 → 写 0002-critique.md
Claude: 读取 critique → 修订 → 写 0003-plan.md
Codex:  读取 → 写 0004-critique.md
Claude: 收敛方案 → 写 0005-execute.md（进入实施阶段）
```

#### 随时人工介入

你可以在任何时刻直接在 Claude 或 Codex 窗口输入自己的指令：

```bash
# 在 Claude 窗口 — 查看状态
/collab-status

# 在 Claude 窗口 — 只审查不自动继续
/review

# 在 Claude 窗口 — 把讨论中的话题交给 Codex
/handoff 把刚才讨论的缓存策略落地实现

# 在 Codex 窗口 — 补充指令
请同时补充单元测试
```

Relay 有 8 秒注入冷却，不会在你输入时强行插入命令。

---

## 消息协议

### 文件命名

每条消息一个独立文件，只创建不覆盖：

```
0001-plan.md
0002-critique.md
0003-execute.md
0004-progress.md
0005-done.md
```

### 消息格式

每个文件必须包含 YAML frontmatter：

```markdown
---
id: "0003"
from: claude
to: codex
type: execute
round: 2
reply_to: "0002"
status: pending
created_at: 2026-06-20T13:20:00+08:00
---

## Objective
实现用户注册 API

## Acceptance Criteria
- POST /api/register 接受 email + password
- 密码 bcrypt 加密存储
- 返回 JWT token
- 重复邮箱返回 409
```

### 消息类型

| 类型 | 发送方 | 说明 |
|:-----|:-------|:-----|
| `plan` | Claude | 高层方案（分析阶段） |
| `execute` | Claude | 具体实施指令（必须包含验收标准） |
| `critique` | 双方 | 对方案的审查意见 |
| `review` | Claude | 对执行结果的审查 |
| `progress` | Codex | 部分完成，还需继续 |
| `blocked` | Codex | 无法继续（必须说明原因和备选方案） |
| `done` | 双方 | 任务完成（包含验证结果） |
| `needs_human` | 双方 | 需要人工介入 |

### 原子写入规则

消息文件必须通过原子写入方式创建，防止 Relay 读到半成品：

```bash
# 第一步：写入临时文件
cat > .cc-collab/queue/codex/0003-execute.md.tmp << 'EOF'
---
id: "0003"
...
---
...
EOF

# 第二步：原子重命名
mv .cc-collab/queue/codex/0003-execute.md.tmp \
   .cc-collab/queue/codex/0003-execute.md
```

Relay 只扫描 `.md` 文件，不读 `.tmp` 文件。

---

## 状态机

```
idle → planning → critique → executing → reviewing → adversarial_review → done
                                  ↓
                               blocked
                                  ↓
                           manual_override ←── (任一自动停止条件触发)
```

### 自动停止条件

Relay 在以下任一条件满足时进入 `manual_override` 模式：

| 条件 | 默认阈值 | 环境变量 |
|:-----|:---------|:---------|
| 达到最大轮数 | 20 | `CC_MAX_ROUNDS` |
| 连续空轮询 | 9999 | `CC_MAX_EMPTY` |
| 连续阻塞消息 | 3 | `CC_MAX_BLOCKED` |
| 同类消息重复 | 6 | `CC_MAX_TYPE_REPEAT` |
| 空闲超时 | 900 秒 | `CC_MAX_IDLE` |

### 恢复自动模式

```bash
# 方式 1: 创建 resume 信号文件
touch .cc-collab/state/resume

# 方式 2: 先查看状态再决定
cat .cc-collab/state/current.json | jq .

# 方式 3: 完全重置
bash relay.sh --reset
```

除 `needs_human` 类型的停止外，当队列中出现新消息时 Relay 会自动恢复。

---

## 配置参考

所有配置通过环境变量设置，在运行 `start.sh` 前 export：

```bash
export CC_MAX_ROUNDS=30              # 最大协作轮数
export CC_MAX_IDLE=1200              # 空闲超时（秒）
export CC_POLL_INTERVAL=5            # 队列轮询间隔（秒）
export CC_MIN_INJECT_INTERVAL=12     # 注入冷却时间（秒）
export CC_TMUX_SESSION=my-collab     # tmux 会话名
export CC_COLLAB_DIR=./.cc-collab    # 通信目录路径

bash ~/tools/cc-collab-v2/start.sh
```

| 变量 | 默认值 | 说明 |
|:-----|:-------|:-----|
| `CC_COLLAB_DIR` | `./.cc-collab` | 通信根目录 |
| `CC_TMUX_SESSION` | `cc-collab` | tmux 会话名 |
| `CC_POLL_INTERVAL` | `3` | 队列扫描间隔（秒） |
| `CC_MAX_ROUNDS` | `20` | 最大协作轮数 |
| `CC_MAX_IDLE` | `900` | 空闲超时（秒） |
| `CC_MAX_EMPTY` | `9999` | 连续空轮询上限 |
| `CC_MAX_BLOCKED` | `3` | 连续阻塞上限 |
| `CC_MAX_TYPE_REPEAT` | `6` | 同类消息重复上限 |
| `CC_MIN_INJECT_INTERVAL` | `8` | 同一 pane 注入最小间隔（秒） |

---

## 可靠性机制

### ACK 去重

每条消息派发后生成 ACK 文件（`state/ack-{id}-{target}`），确保每条消息对每个目标只派发一次。

### 目录锁

Relay 使用 `mkdir` 原子锁（`state/relay.lock/`），内含 PID 文件。支持自动检测并清理已崩溃进程遗留的过期锁，防止多实例并发冲突。

### 注入冷却

可配置的冷却时间（默认 8 秒），防止在 AI 还在处理上一条消息时就注入新命令。

### 短命令注入

Relay 只注入最短的触发命令：

- **给 Claude**：`/next`（4 个字符）
- **给 Codex**：`New task: read <路径> and follow your AGENTS.md protocol.`

所有实际内容通过文件传递，不通过终端输入注入长文本。

### 对抗审查门控

当 Claude 标记任务为 "done" 时，Relay 会自动触发对抗审查阶段，在真正完成前进行独立的批判性审查：

- 边界情况和缺失的错误处理
- 安全漏洞（注入、鉴权绕过、数据泄露）
- 性能问题（N+1 查询、无界循环、内存泄露）
- 缺失的测试覆盖

### 事件日志

- `logs/events.jsonl` — 结构化事件日志（机器可读）
- `logs/relay.log` — 人类可读的中继日志

---

## 目录结构

初始化完成后，你的项目中会包含：

```
你的项目/
├── CLAUDE.md                        # Claude 协作协议（追加到已有文件末尾）
├── AGENTS.md                        # Codex 协作协议
├── .codex/instructions.md           # Codex 协议（同步副本）
├── .claude/commands/
│   ├── plan.md                      # /plan 命令
│   ├── next.md                      # /next 命令
│   ├── review.md                    # /review 命令
│   ├── handoff.md                   # /handoff 命令
│   ├── collab-status.md             # /collab-status 命令
│   └── adversarial-gate.md          # /adversarial-gate（Relay 自动触发）
└── .cc-collab/
    ├── queue/
    │   ├── claude/                   # 发给 Claude 的消息（来自 Codex）
    │   └── codex/                    # 发给 Codex 的消息（来自 Claude）
    ├── archive/                      # 历史消息归档
    │   └── 20260620-r2/
    ├── state/
    │   ├── current.json              # 状态机
    │   ├── relay.lock/               # 目录锁（含 PID）
    │   ├── ack-0001-codex            # ACK 文件
    │   └── resume                    # 恢复信号
    ├── logs/
    │   ├── relay.log                 # 可读日志
    │   └── events.jsonl              # 结构化事件日志
    └── runtime/
        ├── claude-pane               # tmux pane ID
        ├── codex-pane
        ├── relay-pane
        ├── last_inject_claude        # 最后注入时间戳
        └── last_inject_codex
```

---

## Relay 命令

```bash
# 正常启动（由 start.sh 自动执行）
bash relay.sh

# 查看当前状态和队列
bash relay.sh --status

# 重置状态（不删除消息文件）
bash relay.sh --reset

# 显示帮助
bash relay.sh --help
```

---

## tmux 速查

| 操作 | 按键 |
|:-----|:-----|
| 切换面板 | `Ctrl+B` 然后 `←` `→` `↑` `↓` |
| 当前面板全屏/还原 | `Ctrl+B` 然后 `z` |
| 翻看历史输出 | `Ctrl+B` 然后 `[`，方向键滚动，`q` 退出 |
| 分离到后台（不关闭） | `Ctrl+B` 然后 `d` |
| 重新连接 | `tmux attach -t cc-collab` |
| 彻底关闭 | `tmux kill-session -t cc-collab` |

---

## 故障排查

<details>
<summary><strong>Relay 反复打印 "pane 未就绪"</strong></summary>

检查 tmux 面板是否存在：
```bash
tmux list-panes -t cc-collab
```
如果不存在，重启会话：
```bash
tmux kill-session -t cc-collab
bash ~/tools/cc-collab-v2/start.sh
```
</details>

<details>
<summary><strong>消息没有被 Relay 检测到</strong></summary>

1. 确认文件名以数字开头：`ls .cc-collab/queue/codex/`
2. 确认后缀不是 `.tmp`
3. 确认没有对应的 ACK 文件：`ls .cc-collab/state/ack-*`
</details>

<details>
<summary><strong>Claude / Codex 没有按协议操作</strong></summary>

在对应窗口中提醒：
```
请按照 CLAUDE.md（或 AGENTS.md）中的 CC-COLLAB 协议操作。
将输出写入 .cc-collab/queue/codex/（或 queue/claude/）目录，文件格式为 .md。
必须先写 .tmp 再 rename 为 .md（原子写入）。
```
如果 AI 持续不遵守协议，在 `CLAUDE.md` 或 `AGENTS.md` 中加强关键规则的措辞。
</details>

<details>
<summary><strong>Relay 进入了 manual_override</strong></summary>

查看原因：
```bash
jq . .cc-collab/state/current.json
```
恢复：
```bash
touch .cc-collab/state/resume
```
</details>

<details>
<summary><strong>想完全重新开始</strong></summary>

```bash
rm -rf .cc-collab/queue/claude/* .cc-collab/queue/codex/*
rm -rf .cc-collab/archive/*
bash ~/tools/cc-collab-v2/relay.sh --reset
tmux kill-session -t cc-collab
bash ~/tools/cc-collab-v2/start.sh
```
</details>

<details>
<summary><strong>AI 响应太慢 / Relay 节奏对不上</strong></summary>

调大冷却和轮询间隔：
```bash
export CC_MIN_INJECT_INTERVAL=15   # 默认 8 秒
export CC_POLL_INTERVAL=5          # 默认 3 秒
bash ~/tools/cc-collab-v2/start.sh
```
</details>

---

## 新手建议

1. **从小任务开始** — 第一次使用建议选一个简单具体的需求（如 "添加一个 API 接口"），不要一上来就给大任务，先熟悉流程。

2. **关注三个面板** — 首次使用时同时观察 Claude、Codex 和 Relay 三个窗口，确认两个 AI 都在按协议写入消息文件。

3. **检查消息格式** — 第一轮完成后，检查消息文件格式是否正确：
   ```bash
   cat .cc-collab/queue/codex/0001-plan.md
   ```
   确认有 YAML frontmatter，确认是通过原子写入创建的。

4. **调校 AI 行为** — 如果某个 AI 不按协议操作，在对应的配置文件（`CLAUDE.md` 或 `AGENTS.md`）中加强关键规则的表述。大模型对协议的遵从度与提示词的写法直接相关。

5. **循序渐进** — 成功跑通第一个完整循环后，再尝试更复杂的多轮任务。

---

## 贡献

欢迎提交 Issue 和 Pull Request。

## 许可证

MIT
