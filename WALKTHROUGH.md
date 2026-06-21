# 实践操作指南：从零跑通 Claude Code + Codex 协作

这份指南面向 Windows + WSL2 环境，带你从环境检查到完整跑通一轮协作循环。每一步都写明了在哪个窗口敲什么、预期看到什么。

整个过程大约 15 分钟。

---

## 第零步：环境检查

打开 WSL2 终端，逐条确认：

```bash
# 1. Claude Code CLI
claude --version
# 预期: Claude Code v2.x.xxx 或类似版本号
# 如果没装: npm i -g @anthropic-ai/claude-code

# 2. Codex CLI
codex --version
# 预期: 0.1xx.x 或类似版本号
# 如果没装: npm i -g @openai/codex

# 3. tmux
tmux -V
# 预期: tmux 3.x
# 如果没装: sudo apt install tmux

# 4. jq
jq --version
# 预期: jq-1.6 或更高
# 如果没装: sudo apt install jq

# 5. 确认 UTF-8（WSL2 有时不是默认）
echo $LANG
# 如果输出不含 UTF-8：
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
# 建议写进 ~/.bashrc 永久生效
```

四个工具全部就绪后继续。

---

## 第一步：放置脚本

把 `cc-collab-v2` 文件夹放到一个固定位置，后续所有项目共用：

```bash
# 建议放在 ~/tools/
mkdir -p ~/tools
cp -r cc-collab-v2 ~/tools/cc-collab-v2
chmod +x ~/tools/cc-collab-v2/*.sh

# 验证
ls ~/tools/cc-collab-v2/
# 预期看到: relay.sh  setup.sh  start.sh  README.md  WALKTHROUGH.md
```

这一步只做一次，以后不用重复。

---

## 第二步：在你的项目中初始化

```bash
# 进入你的项目目录
cd ~/your-project        # ← 换成你的实际路径

# 运行 setup
bash ~/tools/cc-collab-v2/setup.sh
```

**预期输出：**

```
[setup] 创建 .cc-collab/ 完整目录结构...
[setup] 向 CLAUDE.md 追加协作协议...
[setup] 创建 AGENTS.md...
[setup] 已同步到 .codex/instructions.md
[setup] 创建 .claude/commands/ 快捷命令...
[setup] 创建 .gitignore...

  协作环境初始化完成 (v2)
```

**验证：**

```bash
# 检查目录结构
ls .cc-collab/
# 预期: archive  logs  queue  runtime  state

# 检查配置文件
head -3 CLAUDE.md
head -3 AGENTS.md
ls .claude/commands/
# 预期: collab-status.md  handoff.md  next.md  plan.md  review.md
```

如果你的项目已有 `CLAUDE.md`，setup 会在末尾追加协作协议，不会覆盖已有内容。

---

## 第三步：启动协作会话

```bash
# 确保你在项目根目录
cd ~/your-project

# 启动
bash ~/tools/cc-collab-v2/start.sh
```

**预期：** 屏幕切换到 tmux，出现三栏布局：

```
┌──────────────────────┬──────────────────────┐
│    Claude Code       │       Codex          │
│    (正在启动...)      │    (正在启动...)      │
│                      │                      │
├──────────────────────┴──────────────────────┤
│    Relay v2 (正在启动...)                    │
└─────────────────────────────────────────────┘
```

等 3-5 秒，三个面板各自初始化完成：

- 左上：Claude Code 出现交互提示符 `>`
- 右上：Codex 出现交互提示符
- 下方：Relay 打印 `relay 已启动，等待消息...`

**如果 Claude 或 Codex 启动后要求选模型或确认配置，先在各自窗口完成配置。**

面板切换方法：`Ctrl+B` 然后按方向键。

---

## 第四步：发起第一个任务

用 `Ctrl+B` + `←` 确保光标在**左上 Claude 窗口**，然后输入：

```
/plan 在项目中添加一个健康检查接口 GET /healthz，返回 JSON 格式的服务状态
```

把上面的 `/plan` 后面的内容换成你自己项目的实际需求。用你项目实际能做的事，比如：

- `/plan 给现有的用户模块添加密码重置功能`
- `/plan 重构 config 模块，改用环境变量注入`
- `/plan 给 main.py 添加 --verbose 命令行参数`

**你会看到什么：**

Claude 开始分析你的需求，思考后会：

1. 在终端中输出它的分析过程（你能实时看到）
2. 在 `.cc-collab/queue/codex/` 目录中创建一个消息文件，例如 `0001-plan.md`
3. 告诉你"Plan #0001 sent to Codex"或类似确认

---

## 第五步：观察 Relay 接力

Claude 写完计划后，把视线移到**下方 Relay 面板**（`Ctrl+B` + `↓`）。

**预期看到：**

```
[14:23:05] [relay] 消息 #0001 [plan] claude → codex
[14:23:05] [relay]   → codex: New task: read .cc-collab/queue/codex/0001-plan.md and follow your AGENTS.md protocol.
```

这说明 Relay 检测到了 Claude 的计划，已经向 Codex 注入了短命令。

---

## 第六步：观察 Codex 执行

切到**右上 Codex 窗口**（`Ctrl+B` + `→` 再 `↑`），你会看到：

1. Codex 收到了 Relay 注入的短命令
2. Codex 开始读取计划文件
3. Codex 分析计划后开始执行（或先给出 critique）
4. 执行过程中你能看到 Codex 的实时输出——创建文件、写代码、跑测试等
5. 完成后，Codex 将结果写入 `.cc-collab/queue/claude/`，例如 `0002-progress.md`

**全程不需要你做任何操作。** Codex 自动读取、自动执行、自动回报。

---

## 第七步：观察 Claude 审查

Codex 写完结果后，Relay 面板会显示：

```
[14:25:12] [relay] 消息 #0002 [progress] codex → claude
[14:25:12] [relay]   → claude: /next
```

切到**左上 Claude 窗口**，你会看到：

1. Claude 收到了 `/next` 命令
2. Claude 读取 Codex 的结果文件
3. Claude 审查结果，给出评价
4. 如果任务未完成：Claude 自动写下一步计划到 `queue/codex/`，Relay 继续接力
5. 如果任务完成：Claude 输出 done 消息，Relay 自动停止

**就是这样——整个循环自动运转。**

---

## 随时介入

你可以在任何时刻直接在 Claude 或 Codex 窗口输入自己的指令：

```
# 在 Claude 窗口 — 手动查看状态
/collab-status

# 在 Claude 窗口 — 只审查不自动继续
/review

# 在 Claude 窗口 — 把正在讨论的事情交给 Codex
/handoff 把刚才讨论的缓存策略落地实现

# 在 Codex 窗口 — 直接给 Codex 额外指令
请同时补充单元测试
```

Relay 有 8 秒注入冷却，不会在你打字时强行插入命令。

---

## 当 Relay 自动停止时

如果出现以下情况，Relay 会自动进入手动模式并在面板中打印原因：

```
══ 自动停止 ══
原因: 达到最大轮数 (10 >= 10)

已进入手动模式。恢复方法:
  touch .cc-collab/state/resume
```

**你的选择：**

```bash
# 选项 1: 恢复自动模式，让协作继续
touch .cc-collab/state/resume

# 选项 2: 查看当前状态再决定
cat .cc-collab/state/current.json | jq .

# 选项 3: 重置状态，从头开始
bash ~/tools/cc-collab-v2/relay.sh --reset
```

---

## 查看历史记录

所有消息都保留在文件系统中：

```bash
# 看队列中当前的消息
ls .cc-collab/queue/claude/
ls .cc-collab/queue/codex/

# 看已归档的历史消息
ls .cc-collab/archive/

# 读某一条消息的内容
cat .cc-collab/queue/codex/0001-plan.md

# 看 Relay 事件日志
tail -20 .cc-collab/logs/events.jsonl | jq .

# 看 Relay 可读日志
tail -20 .cc-collab/logs/relay.log
```

---

## tmux 生存指南

你会频繁用到这些操作：

| 你想做什么 | 按什么 |
|-----------|--------|
| 切到左边/右边/上面/下面的面板 | `Ctrl+B` 然后 `←` `→` `↑` `↓` |
| 把当前面板全屏查看 | `Ctrl+B` 然后 `z`（再按一次还原） |
| 往上翻看历史输出 | `Ctrl+B` 然后 `[`，用方向键或 PgUp 滚动，`q` 退出 |
| 暂时离开但不关闭 | `Ctrl+B` 然后 `d`（分离到后台） |
| 回来继续 | `tmux attach -t cc-collab` |
| 彻底关闭 | `tmux kill-session -t cc-collab` |

---

## 如果出了问题

**Claude 没有创建消息文件**

Claude 可能没有按照 CLAUDE.md 中的协议操作。在 Claude 窗口中明确提醒：

```
请按照 CLAUDE.md 中 CC-COLLAB 协议的格式，把计划写入 .cc-collab/queue/codex/ 目录。
文件名格式 0001-plan.md，先写 .tmp 再 rename。
```

**Codex 没有按协议回复**

同理，在 Codex 窗口提醒：

```
请按照 AGENTS.md 中的协作协议格式，把执行结果写入 .cc-collab/queue/claude/ 目录。
```

**Relay 说 pane 不存在**

tmux 面板可能挂了。关掉重来：

```bash
tmux kill-session -t cc-collab
bash ~/tools/cc-collab-v2/start.sh
```

**想完全重新开始**

```bash
# 清空所有消息和状态
rm -rf .cc-collab/queue/claude/* .cc-collab/queue/codex/*
rm -rf .cc-collab/archive/*
bash ~/tools/cc-collab-v2/relay.sh --reset

# 重新启动
tmux kill-session -t cc-collab
bash ~/tools/cc-collab-v2/start.sh
```

**Relay 和 Claude/Codex 的节奏对不上**

调大注入冷却时间，给 AI 更多处理时间：

```bash
export CC_MIN_INJECT_INTERVAL=15   # 从默认 8 秒改到 15 秒
export CC_POLL_INTERVAL=5          # 从默认 3 秒改到 5 秒
bash ~/tools/cc-collab-v2/start.sh
```

---

## 进阶用法

### 需求分析阶段（多轮互审）

如果你想让 Claude 和 Codex 先就方案进行多轮讨论再动手：

```
/plan 设计一个高并发订单处理系统的技术方案。
注意：这一步只做架构分析和方案评审，不要直接实施。
请产出 type 为 plan 的消息，等 Codex 的 critique 反馈后再迭代。
最多 3 轮互审后收敛为一个 execute 计划。
```

### 指定模型

在 Claude 或 Codex 窗口内分别切换：

```
# Claude 窗口
/model

# Codex 窗口
/model
```

### 调整自动停止阈值

```bash
# 启动前设置
export CC_MAX_ROUNDS=20            # 允许更多轮
export CC_MAX_IDLE=600             # 空闲超时 10 分钟
bash ~/tools/cc-collab-v2/start.sh
```

---

## 第一次实践的建议

1. 选一个小且具体的需求开始，比如"添加一个 API 接口"或"写一个工具函数"。不要一上来就给大任务——先熟悉流程。

2. 全程关注三个面板。第一次不要完全放手，观察 Claude 和 Codex 是否按照协议写入消息文件。如果某一方没有按格式写，手动提醒一下。

3. 跑完第一轮后，用 `cat .cc-collab/queue/codex/0001-plan.md` 看看消息格式是否正确——有没有 YAML frontmatter，有没有原子写入。这能帮你判断两个 AI 是否理解了协议。

4. 如果某一方始终不按协议来，在它的配置文件（CLAUDE.md 或 AGENTS.md）中把关键规则加粗或重复强调。大模型对协议的遵从度和提示词的写法强相关。

5. 第一次成功跑通完整循环后，再试更复杂的任务。
