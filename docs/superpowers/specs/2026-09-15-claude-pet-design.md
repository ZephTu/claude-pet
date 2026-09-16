# Claude Pet 设计文档

> 2026-09-15 · 一只常驻 macOS 桌面、反映本机全部 Claude Code session 状态的宠物

## 要解决的问题

我日常同时开十几到几十个 Claude Code session（实测过去 10 小时有 51 个 session 文件被写过，横跨 16 个 project 目录）。问题不是"活干不完"，是**你不知道哪个 session 现在需要你**——尤其是某个 session 卡在等授权、等输入，你不知道，它就在那儿空转十分钟。

现有的 `notify-done.sh` 只覆盖了"干完了"这一个时刻，而且是系统通知，一闪就没。缺的是一个**持续在场的、余光扫一眼就知道全局状态**的东西。

宠物就是干这个的：它不告诉你细节，它只让你知道"现在要不要管"。

## 不做什么

- 不做喂食、换装、养成
- 不做聊天框，不接 Anthropic API（宠物不说话，只表达状态）
- 不发系统通知、不出声（`notify-done.sh` 已经覆盖完成通知，不重复）
- 不做跨机器、不做远程 session

## 一、架构

三个进程，文件当总线，不建任何连接：

```
Claude Code session ×N          宠物 app（常驻）
       │                              │
   hooks 触发                    FSEvents 监听
       │                              │
       ▼                              ▼
~/.claude/pet/sessions/<id>.json ──► StateAggregator ──► WKWebView 里的宠物
```

不开端口、不开 socket、不常驻 daemon。hook 脚本唯一做的事是往 `~/.claude/pet/sessions/<sessionId>.json` 写一个几百字节的 JSON，宠物 app 用 FSEvents 监听这个目录，一有变化就重算全局状态。

**为什么是文件不是 socket**：现有的 hooks 链路上已经挂了 6 个脚本，每个 session 每次工具调用都要跑一遍，宠物绝不能拖慢它。写文件是 1-2ms，而且宠物 app 崩了、没开、正在重编译，hook 照样写，Claude Code 一点感觉都没有——反向也成立，hook 出错不影响宠物。

**技术栈**：Swift AppKit `NSPanel` 壳 + `WKWebView` 渲染宠物。壳负责窗口行为（这部分写完基本冻结），宠物本身是本地 HTML/SVG，表情动画改一行看一次效果。常驻内存预期 60-80MB。本机 Swift 6.4 + Command Line Tools 已足够编译，不需要完整 Xcode（纯 SwiftPM，无 `.xcodeproj`）。

## 二、状态从哪来

六个 hook 事件覆盖宠物要表达的全部状态：

| hook | 写入 state | 宠物表现 |
|---|---|---|
| `SessionStart` | `idle` | 抬头（一次性） |
| `UserPromptSubmit` | `busy` | 精神一振，开始忙 |
| `PreToolUse` | `busy` + `tool` | 瞎忙 |
| `PostToolUse` | `busy` | 瞎忙 |
| `Notification`（message 含 `needs your permission`） | `waiting` | 急，跳 |
| `Notification`（message 含 `waiting for your input`） | `idle` | 不跳，只在展开面板里标「说完了」 |
| `Stop` | `idle` | 弹一下（一次性），然后慢慢回到打瞌睡 |
| `SessionEnd` | —— | 删掉状态文件，从列表里立刻消失 |

`Notification` 是白捡的信号，但**必须按 message 分流**：Claude Code 用同一个 hook 发两种完全不同的事——
`Claude needs your permission to use X` 是 session 真卡住了，不授权就不动；`Claude is waiting for your input` 只是说完了在等你回话，根本没卡。
两者都当成"在等你"的话，宠物会为一个压根没卡住的 session 一直跳到你敲回车为止（2026-09-15 上线当天实测踩到）。
认不出来的 message 一律按前者处理——误报一次，比漏掉一个真卡住的 session 便宜。

`SessionEnd` 同样重要：没有它，关掉的 session 会以「闲着」的样子在列表里赖满 15 分钟才被超时剔除。

### 状态文件格式

路径 `~/.claude/pet/sessions/<sessionId>.json`，每个 session 一个文件，hook 全量覆写：

```json
{
  "sessionId": "55fa95c7-8435-40dc-8fd2-b828bd441707",
  "project": "multica",
  "cwd": "/Users/dev/Projects/demo-app",
  "state": "busy",
  "tool": "Bash",
  "detail": "",
  "since": "2026-09-15T10:20:00Z",
  "updatedAt": "2026-09-15T10:23:45Z"
}
```

- `project`：`cwd` 的 basename，宠物展开面板时显示的名字
- `state`：`waiting` / `busy` / `idle` 三选一
- `tool`：`PreToolUse` / `PostToolUse` 带的 `tool_name`，其余事件为空
- `detail`：`Notification` 事件的 message，其余为空。只在展开面板里显示，不进气泡（气泡只写 project 名，要短到一眼看完）
- `since`：进入当前 `state` 的时刻。用于 60 秒升级判定。因为 hook 是全量覆写，脚本要先读一次旧文件：
  旧 `state` 与新的相同就沿用旧 `since`，不同才刷成当前时刻。读不到旧文件（首次写入）直接用当前时刻
- `updatedAt`：本次写入时刻，用于死 session 判定

hook 脚本 `pet-emit.sh` 从 stdin 读 Claude Code 传入的 JSON（含 `session_id`、`cwd`、`hook_event_name`、`tool_name`、`message`），映射成上面的结构写出。脚本必须无条件 `exit 0`——宠物的任何问题都不能让 Claude Code 的 hook 链路报错。

## 三、全局状态聚合

一只宠物代表所有 session，`StateAggregator` 负责把 N 个 session 状态合成 1 个。

**剔除死 session**：正常退出走 `SessionEnd`，状态文件当场删掉。但终端被强杀时 `SessionEnd` 不触发，所以还要第二层：`updatedAt` 超过 15 分钟的直接丢弃。两层都得有——只靠超时，关掉的 session 要在列表里赖十几分钟；只靠 `SessionEnd`，被强杀的 session 会永远假装在忙。丢弃只影响聚合结果，文件由宠物 app 顺手删掉。

**优先级：急 > 忙 > 闲**

1. 任何一个 session `waiting` → 全局 `waiting`
2. 否则任何一个 `busy` → 全局 `busy`
3. 否则 → 全局 `idle`

**升级判定**：全局为 `waiting` 时，取所有 waiting session 里最早的 `since`，超过 60 秒则升级为 `urgent`。

**存活判定查进程，不看时间戳**。一个开着但没人操作的 session 不触发任何 hook，`updatedAt` 就停在原地——按时间判断会让它在 15 分钟后从面板上消失，而它活得好好的。所以 pet-emit 记录 Claude Code 进程的 pid，宠物用 sysctl 查它还在不在。两个坑：内核的 `p_comm` 是 `claude.exe` 而不是 `claude`（`ps -o comm` 显示的是 argv[0] 的 basename，`ucomm` 才是 p_comm），所以按前缀匹配；pid 会被复用，所以光"这个 pid 活着"不够，必须同时核对进程名。900 秒超时保留，但只用于升级前写的、没有 pid 的老状态文件。

**一次性事件**：`SessionStart`（抬头）和 `Stop`（弹一下）是瞬时动画，不是持续状态。聚合器除了输出持续状态，还输出一个一次性事件队列推给前端播一次，播完回到持续状态对应的表情。

### 表情映射

| 全局状态 | 天线灯 | 动作 |
|---|---|---|
| `idle` | 灭 | 趴桌上睡着，头顶飘 zzz，显示器全黑，慢呼吸 |
| `busy` | 绿灯慢闪 | 双手在键盘上交替敲，脸转向屏幕，屏幕代码行依次刷新 |
| `waiting` | 黄灯脉冲 | 手离开键盘，转过来朝你招手 |
| `urgent` | 红灯急闪 | 双手举过头顶，整体抖动倾斜，头顶气泡写出是哪个 project 在等你 |

形象是一只坐在电脑桌前的小机器人（胸口 SN），不是原设计的 Claude 星芒。换形象的原因是星芒只能靠"跳不跳"区分状态，而机器人多出天线灯这个**独立的高饱和色点**——在 120pt 尺寸下不用聚焦就能读到颜色，比任何表情都醒目。

`urgent` 仍然不响、不弹系统通知。它只是在余光里变得难以忽略——永远不打断你，但眼睛扫过桌面就一定会发现。

## 四、窗口行为

`NSPanel` 的关键配置，每一项对应一个具体的烦人问题：

- `LSUIElement = true`：不进 Dock、不占 `Cmd-Tab`
- `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded`：点它不抢焦点。你在终端里打字时点一下宠物，光标还在终端
- `.canJoinAllSpaces` + `.stationary`：跟着切 Space
- `level = .floating`：浮在普通窗口之上，但不压全屏应用。用 `.screenSaver` 级别会导致全屏看视频时它杵在上面
- `ignoresMouseEvents` 按区域动态开关：宠物周围的透明区域鼠标直接穿透打到底下的窗口，只有宠物身体本身能点。
  做法是装一个全局鼠标移动监听，鼠标进入 panel 矩形时判断当前坐标是否落在宠物的命中区内，透明就开穿透、不透明就关。
  只在鼠标位于 panel 矩形内时做这个判断，不是每次鼠标移动都算。
  命中区是 `PetLayout.bodyBox`（机器人+桌子，一块宽扁矩形）加 `PetLayout.antennaBox`（天线和状态灯，单独一小块）。
  用矩形而不是真实 alpha：取真实像素 alpha 要走 `takeSnapshot`，异步且太贵，不可能每次鼠标移动都跑一遍。
  `bodyBox` 的上边距刻意留够了 `urgent` 抖动的 5pt 抬升和 3° 倾斜，所以命中区不需要跟着动画状态变——这是它比原来的圆形+跳跃补偿简单的地方

## 五、交互

**左键点一下** → 旁边滑出半透明小面板，列当前活跃 session：project 名、在忙什么、多久了。再点收起。这是"一只宠物总管全局"的补偿:平时只看表情，要细节才展开。

**点面板里的某一行** → 跳回那个 session 所在的终端标签页，面板随之收起。只有能定位到标签页的行可点，右侧带一个 ↗ 作为常驻提示，鼠标移上去整行高亮。

pet-emit 在 hook 里从 session 自己的环境变量认终端：Orca 给 `ORCA_TERMINAL_HANDLE`，iTerm2 给 `ITERM_SESSION_ID`。两者都是普通导出变量、会被子进程继承，所以用 `TERM_PROGRAM` 消歧——它指的才是真正承载这个 shell 的终端；`TERM_PROGRAM` 指向一个我们跳不了的终端时直接放弃，绝不拿继承来的过期 handle 去跳。

跳转本身：Orca 调它自带的 CLI（`orca terminal switch --terminal <handle> --json`），不需要任何 macOS 权限，但**必须解析 JSON 里的 `ok` 字段**——handle 失效时它照样退出 0，只看退出码会把 Orca 拉到前台却停在别的标签页。iTerm2 只能走 AppleScript，需要自动化权限，Info.plist 必须带 `NSAppleEventsUsageDescription`，否则 macOS 连问都不问直接拒绝。

session id 会被拼进 AppleScript 字符串执行，是整个功能里唯一危险的输入，所以只允许十六进制字符和连字符。

**同目录多个 session 时，名字常驻显示在第二行**（占掉 notification 那一行）。第二行是有成本的，所以只花在真有歧义的地方：目录里只有一个 session 时一切照旧。

**悬停 0.45 秒显示 session 名字**。面板里的 project 列是目录名，同一个仓库开三个 session 完全分不清。真正能区分它们的是终端标签的标题。Claude Code 自己不记这个名字——transcript 里没有 summary 行，旁边也没有元数据文件——所以只能去问终端：Orca 走 `terminal list --json`，iTerm2 走 AppleScript（session 自己没有 title 属性，标题在 tab 上）。

标题前面那个会动的状态符号（✳ ◐）必须剥掉，否则同一个 session 每秒看起来都在改名。`Terminal 1` 这种默认名当作没有，不值得占一次悬停。

查询只在**用户展开列表时**发生，不是定时轮询：它要起一个子进程，没人在看的面板没资格这么做。

**鼠标悬停高亮只能由 Swift 驱动**：页面收不到任何鼠标事件（见第四节），CSS `:hover` 在这里永远不触发。

**静音某个 session**：悬停那一行时行尾出现 ×，点它把这个 session 从列表里拿掉。静音的 session 同时不参与表情聚合——否则宠物会为一个用户看不见的 session 举手报警，比看到它更烦。

解除静音的条件是**用户又跟它说话了**，不是超时、也不是手动取消。所以 pet-emit 单独记一个 `lastPromptAt`，只在 `UserPromptSubmit` 时更新；session 自己跑工具、自己说完话都不更新，否则一个长任务会立刻把自己解除静音。静音时存下的是**那一刻该 session 的 `lastPromptAt`**，而不是静音的时刻——拿墙上时间比会让"静音前刚说过话"的 session 立刻回来。

记录存 UserDefaults，按 sessionId 索引，session 退出后自动清理，不会无限增长。

`lastPromptAt` 是 `Date?`，而 Optional 只覆盖"字段缺失"，不覆盖"字段是空字符串"——后者会抛错并让整条 session 从面板静默消失。所以 `SessionState` 手写了 `init(from:)`，所有可选字段用 `try?` 容错，必填字段仍然照常抛（没有 `state` 的文件本来就不是一个 session）。

**拖拽** → 换位置，退出时记住坐标（`UserDefaults`），下次启动回原位。

**右键** → 三项菜单：暂停（宠物睡死不再反应）、开机自启开关、退出。

## 六、代码组织

```
~/Documents/Code_Projects/claude-pet/
├── Package.swift
├── Sources/ClaudePetCore/       # 纯逻辑，可测，不碰 AppKit
│   ├── SessionState.swift       # 状态文件的模型与解析
│   ├── GlobalState.swift        # 聚合结果
│   └── StateAggregator.swift    # 急>忙>闲 合并、死 session 剔除、urgent 升级
├── Sources/ClaudePet/           # GUI，不放逻辑
│   ├── AppMain.swift            # NSApplication 启动 + LSUIElement
│   ├── PetPanel.swift           # 第四节那套窗口配置
│   ├── SessionWatcher.swift     # FSEvents 监听 sessions/ 目录，读文件
│   ├── WebBridge.swift          # Swift → JS 状态推送
│   └── PetMenu.swift            # 右键菜单
├── Sources/ClaudePetTests/      # 测试也是可执行程序，见第八节
│   ├── Harness.swift
│   └── Runner.swift
├── Resources/pet/
│   ├── index.html
│   ├── pet.css                  # 机器人 SVG 配色 + 各状态动画
│   └── pet.js                   # 收状态 → 切表情
├── hooks/
│   ├── pet-emit.sh              # 装进 ~/.claude/ 的 hook 脚本
│   └── test-pet-emit.sh
└── scripts/
    ├── build-app.sh             # SwiftPM 产物手工打成 .app bundle
    ├── install.sh               # 备份 settings.json → 追加 hooks → 装 app
    └── uninstall.sh
```

逻辑放在独立的 `ClaudePetCore` target 而不是和 GUI 混在一起，是因为测试程序只能链接 library：可执行 target 没法被另一个可执行 target 依赖。这条约束顺带逼出了正确的分层。

入口文件叫 `AppMain.swift` 而不是 `main.swift`：Swift 6 里 top-level 代码隐含 `@MainActor`，且不允许给 top-level 变量标注 global actor，`@main struct` 是唯一干净的写法。

每个 Swift 文件只干一件事，互相之间靠明确的数据结构通信：`SessionWatcher` 吐 `[SessionState]`，`StateAggregator` 吃 `[SessionState]` 吐 `GlobalState`，`WebBridge` 吃 `GlobalState` 推给前端。三者都能单独看懂、单独改。

## 七、对现有配置的改动

只有一处，而且是**追加不是覆盖**：往 `~/.claude/settings.json` 已有的 hooks 数组里各加一条 `pet-emit.sh`。现有的 `notify-done.sh`、`log-session-for-ingest.sh`、orca 的 `claude-hook.sh`、`check-test-cases-needs-validation.py` 一行不动。

`Notification`、`UserPromptSubmit`、`SessionEnd` 目前没配，是新增数组，不碰任何现有内容。

`install.sh` 改之前先备份 `settings.json`，并且校验改完的 JSON 合法（`jq` 解析一遍）——settings.json 写坏了所有 session 都会受影响，这是整个项目风险最高的一步。

## 八、测试

**`StateAggregator` 是纯函数，全覆盖**——这是唯一有真正逻辑的地方：

- 急 > 忙 > 闲的优先级，包括多个 session 混合状态
- 死 session 超时剔除（边界：正好 15 分钟、14:59、15:01）
- `urgent` 升级判定（边界：59 秒、60 秒、61 秒），以及取最早 `since` 而不是最晚
- 空输入（一个 session 都没有）→ `idle`
- 状态文件字段缺失或 JSON 损坏 → 跳过该文件，不崩

边界值取严格语义：`updatedAt` 距今正好 15 分钟算活着，15 分 01 秒才算死；`since` 距今正好 60 秒还是 `waiting`，61 秒才升 `urgent`。

**测试框架用自建 harness，不用 XCTest / swift-testing**——本机只有 Command Line Tools，没装完整 Xcode，`XCTest.framework` 和 swift-testing 的 `TestingMacros` plugin 都不在 CLT 里，`swift test` 会直接编译失败（已实测）。

替代方案是一个约 40 行的断言 harness 做成独立 executable target，`swift run ClaudePetTests` 运行，全绿退出码 0、有失败退出码 1。TDD 的红绿循环完全成立，代价是没有 `XCTest` 的 fixture、参数化和并行那些便利——对 `StateAggregator` 这种纯函数来说用不上。

**不写自动化测试的**：窗口行为（置顶、穿透、跟随 Space）和表情动画，肉眼验，写 UI 自动化不值当。

## 九、上线方式

先手动 `open ClaudePet.app` 跑几天，窗口行为和表情节奏调顺了，再挂 `LaunchAgent` 开机自启。一上来就自启，出问题还得先找怎么关掉它。
