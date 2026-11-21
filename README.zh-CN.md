# Claude Pet

[English](README.md) · **中文**

[![CI](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml/badge.svg)](https://github.com/ZephTu/claude-pet/actions/workflows/ci.yml)

给在 Mac 上同时开着很多个 Claude Code session 的人用的两样东西：

- **桌宠**：一只坐在桌面上的猫，一眼就能看出所有 session 在干什么——在干活、干完了、还是在等你。
- **任务看板**：猫背后的一个窗口，记的是**事情**本身：每个 session 是为了什么、它问过你什么、你还欠它什么。session 随时可以关，下一个接着干。

<img src="docs/images/cat.gif" width="300" alt="猫过完一轮：睡着、开工、举爪等你批准、被晾久了大叫、批准后接着干、完成欢呼、再睡回去">

## 桌宠：一眼看清所有 session

猫的姿势就是所有 session 合起来的状态：全都停了就睡着，有人在干活就趴着敲键盘，有 session 等你授权或回答就举起爪子，被晾了一分钟就站起来大叫。它不出声、不发系统通知，只是在你余光里变一变。

![猫能显示的所有状态](docs/images/cat-states.png)

- **点猫**打开 session 列表，按谁更需要你分组：**需要你**（等授权、等回答）、**刚结束**（你还没看的那几轮，每行带 Claude 最后一句话的第一行）、**在跑**。
- 在列表里直接 **Allow / Deny** 授权请求，不用回终端；终端和这里谁先回答算谁的。
- 点 ↗ **跳到 session 所在的终端标签页**：支持 Orca、iTerm2、Ghostty 1.4+，以及 VS Code / Cursor（跳到对应窗口）。
- **完成气泡**说出是哪个 session 刚干完、说了什么；猫耳朵边上的数字是还没看的条数。
- **鼠标停在猫身上**看 5 小时和每周额度；**停在某一行上**看它的路径、context 用量、模型和最后一次工具调用。列表里每行的 context 显示成 `210k·70%`：token 数，以及它占自动 compact 门槛（`/autocompact` 设的值，只读用户级 settings）的比例；会话越过门槛的 2/3 时小猫会提醒一次。
- 在某一行上可以**静音、推迟、改名、置顶**。静音的 session 在你下次给它打字时自动回来。
- 能发现**原地打转**的 session（连续四次工具调用失败），以及一轮结束后**还在后台跑**的命令。

**完整说明**——每种状态、每个按钮、以及为什么这样设计：[docs/pet.zh-CN.md](docs/pet.zh-CN.md)。

### 桌宠看不到的东西

- **只认安装之后新开的 session。** hook 在 session 启动时加载，装之前就开着的窗口要重开才看得到。
- **按 Esc 打断没有任何信号。** Claude Code 打断时一个 hook 都不发，所以宠物改看 Claude Code 自己的会话状态：这种轮次大约 10 秒后显示成 *No recent activity*（读不到状态时是 90 秒），而不是"干完了"。
- **在等后台 agent 的那一轮不算"干完"。** 它显示成在等，等 agent 把 session 唤醒、真正结束时才报完成。
- **多选题提问**（`AskUserQuestion`）没法在桌宠上回答——你勾的选项就是答案，所以点这一行会跳回终端。
- **跳转和发消息取决于终端。** 跳转：Orca、iTerm2、Ghostty 1.4+；VS Code 系编辑器只能跳到对的窗口、不一定是对的终端标签；其他终端没有 ↗。从任务看板发消息：只支持 Orca 和 iTerm2。后台 `claude --bg` session 根本没有终端。
- **额度、context、模型要靠状态栏。** Claude Code 只把这些交给状态栏命令，得有 [claude-hud](https://github.com/jarrodwatts/claude-hud) 或 `pet-emit --statusline` 把它们存下来（[配置方法](docs/pet.zh-CN.md#可选从你的-statusline-读额度)）。不配的话其他功能照常。
- **只支持 macOS 14 以上**，没有 Apple 开发者签名（安装脚本会去掉隔离标记，Gatekeeper 可能还会再问一次）。点击穿透按矩形算，不是按猫的轮廓。动画时大约占一个核的 7%、310 MB 内存。

## 任务看板

session 一多、分散在好几个仓库里，难的就不再是干活本身，而是记住每个 session 是干嘛的、它问过你什么、你回答了没有。任务看板（HQ）把这些从对话里搬到**任务卡**上：每件事一张卡，有状态、下一步、待办和日志。绑定到任务的 session 开工前先读卡、干完把进展写回去，所以记录在卡上，不在某一段对话里。

**双击猫**打开它（或者右键 → **Task Board…**）。

<img src="docs/images/board-today.png" width="900" alt="Focus 页：你正在关注的任务，每个任务带着它未回答的问题、待办和 session；右边是它们的 session">

看板有三个页面，每页两列。**Focus** 只显示你正在关注的任务（不按天清空），每个任务带着它需要你做的一切：没回答的问题、你的待办、在为它干活的 session。**All** 是所有任务和所有 session；**Needs you** 汇总所有没回答的问题和你的待办，标签上有数量。第四个标签 **定时任务** 按时间表自动跑任务（见下文）。底部状态栏显示各类计数和额度；项目、分类和 session 的启动方式都在 ⚙ 设置里。

### 一次回答多个问题

session 在回复末尾列出需要你回答的问题，它们变成看板上的**问题（ask）**，一直留着直到你回答——没回答的不会被当成"不做"。每条可以选 **Yes**（好 / 按建议来；或者在说明里写你自己的答案，可以多行、贴截图）、**No**、**Later**（问题留着，隐去到第二天再出现，session 会知道你稍后再答），或者 **To todo**（其实是你自己要去做的事，转成待办）。一个任务有好几条时，逐条选好，再合成一条消息一起发：

<img src="docs/images/board-asks.gif" width="700" alt="同一个 session 的三个问题：逐条选好回答，第一条写了说明、第三条转成待办，然后一起发出">

回答会直接发进提问的那个 session（Orca 和 iTerm2），或者在它下一轮开始时送达。一个任务有好几个 session 时，只告诉提问的那一个。

### 所有任务、所有 session

<img src="docs/images/board-all.png" width="900" alt="All 页：左边按项目分组的任务，右边是所有在跑的 session">

**All** 是完整的看板：左边是按项目或状态分组的任务，右边是所有在跑的 session——圆点和小猫列表一致，带 context 用量；干完了你还没看的那一轮有个红色 **new** 标记。

<img src="docs/images/board-task.png" width="900" alt="展开一个任务：状态行、待办（Claude 的待办有 Do it 按钮）、在跑的 session、可以 Resume 的以前的 session、日志">

展开任务看卡片的其余部分：

- **待办**：`@me` 是你的，`@claude` 是 session 的。**▶ Do it** 把一条 Claude 待办交给这个任务的 session，或者新开一个 session 去做。
- **Session**：绑定一个在跑的、在任务目录里新开一个，或者 **↻ Resume** 续上以前的某个 session。
- **日志**：决定和发现，时间精确到秒；session 会读它。

### 在看板上和 session 对话

<img src="docs/images/board-peek.png" width="900" alt="对话窗口：一个 session 最近的消息，带格式显示，底部是回复框">

👁 打开一个 session 最近的对话，在底部的框里回复（也可以粘贴或拖入图片），效果和你在终端里亲手输入一样，session 正忙时会排队。

### 定时任务

**定时任务** 标签页按时间表跑一段 Claude prompt（`claude -p`，可以用技能和 MCP 工具）或一条 Shell 命令——每隔 N 分钟、每天、工作日、每周几或 cron——并列出所有任务、最近几次运行、下次运行时间，每次运行的回复、过程和日志都能点开看。任务由 launchd 运行，猫关着也照跑；失败时小猫会提醒。每个任务可以选每次新开 session（只保留最近几次），或一直接着同一个 session。这一页有中英文两版。

**还有一些小事：** 正在输入的草稿重启后还在；删除、解绑都要点两下确认；看板里有中英文的使用说明（**Guide**）。

HQ 是可选的，装完桌宠后单独安装。原理、`hq` 命令行和任务卡格式见 [hq/README.md](hq/README.md)。

## 安装

需要：macOS 14+、[Claude Code](https://claude.com/claude-code)、从源码编译用的 Swift 工具链（Xcode Command Line Tools）。HQ 另外需要 `python3`（只用标准库）。

```bash
./scripts/install.sh                              # 桌宠
hq/install.sh --root ~/claude-hq                  # 可选：任务看板；先列出每一项改动，确认后才执行
hq/install.sh --root ~/claude-hq --no-hooks       # 只装看板和命令行，不碰 settings.json
```

**桌宠的安装脚本会改 `~/.claude/settings.json`**：追加十一个 hook，你原有的一个字节都不动；改之前先备份，原子写入、写完校验。HQ 再加三个（除非用 `--no-hooks`），只在绑定了任务的 session 里起作用。hook 只对**新开**的 session 生效。

**`scripts/install.sh` 装的是它所在的那份代码**，所以它会先抓取 `origin/main`（20 秒没响应就放弃，用上次抓到的副本），再检查这份代码是否包含它的全部提交。如果不包含（比如某个修复合并之前就切出来的功能分支），它会列出缺的提交并停下；在交互式终端里运行时会先问你。加 `--force`（或设 `CLAUDE_PET_INSTALL_ANYWAY=1`）才会照装。否则装上去的小猫会悄悄少掉已经合并的修复。

它存什么：每个 session 当前的状态、每结束一轮一条记录（保留 7 天），以及**每段对话的一行**——Claude 最后那条回复的第一行。你的提问一个字都不存，桌宠**不发任何网络请求**。任务看板为了显示最近的消息，会读本机的对话记录，不会发到任何地方。详见 [docs/pet.zh-CN.md](docs/pet.zh-CN.md#它在你机器上放了什么)。

```bash
./scripts/uninstall.sh      # 摘掉 hook、删掉 app 和开机自启；settings.json 回到装之前的样子
hq/uninstall.sh             # 摘掉 HQ 的 hook 和命令；任务卡保留
./scripts/package.sh        # 打一个带预编译二进制和一键安装脚本的包，发给别人
```

## 更多

- [docs/pet.zh-CN.md](docs/pet.zh-CN.md)：桌宠的完整说明
- [hq/README.md](hq/README.md)：任务看板的原理、`hq` 命令行、任务卡格式
- [docs/development.zh-CN.md](docs/development.zh-CN.md)：测试、调试 hook、改代码之前要知道的三件事

## License

MIT，见 [LICENSE](LICENSE)。
