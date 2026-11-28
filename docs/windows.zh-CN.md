# Windows 上的 Claude Pet

[English](windows.md) · **中文**

Windows 10 / 11（x64）上用的是和 Mac 一样的小猫、一样的任务看板。页面就是 Mac 版的页面，装在一个小的 Electron 程序里显示；hook（`pet-emit.exe`）和 HQ 也是同一份代码，为 Windows 编译。看板有几项功能还只有 Mac 有，见[Windows 上还没有的](#windows-上还没有的)。

## 安装

需要：

- Windows 10 或 11，x64。
- 用官方安装程序装的 [Claude Code](https://claude.com/claude-code)，PATH 里要有 `claude.exe`（npm 装的 `claude.cmd` 见[注意事项](#注意事项)）。
- Git for Windows。Claude Code 本来就要用它的 Git Bash，hook 也在里面跑。
- 任务看板还需要 Python 3.9 以上，从 python.org 装，或者 `winget install Python.Python.3.12`。敲 `python3` 弹出的微软商店占位程序不算。

全程不需要管理员权限。

**1. 下载安装包。** 每次推送到 `main`，CI 都会构建出名为 `ClaudePet-windows` 的产物，保留 90 天。在 GitHub 的 Actions 页面（要登录）找 **Windows** 工作流最近一次成功的运行，下载它；或者用 `gh`：

```powershell
$id = gh run list --repo ZephTu/claude-pet --workflow windows.yml --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId'
gh run download $id --repo ZephTu/claude-pet -n ClaudePet-windows -D ClaudePet-windows
```

**2. 安装桌宠。** 在 PowerShell 里运行：

```powershell
powershell -ExecutionPolicy Bypass -File ClaudePet-windows\install.ps1
```

安装脚本做三件事，然后启动小猫：

- 把 `pet-emit.exe` 和它要用的 Swift 运行库复制到 `%USERPROFILE%\.claude\pet`。
- 往 `%USERPROFILE%\.claude\settings.json` 追加桌宠的 hook。改之前先备份，你自己的设置和 hook 都保留。
- 把程序装到 `%LOCALAPPDATA%\Programs\ClaudePet`，并在开始菜单里加快捷方式。

程序没有签名，第一次运行时 SmartScreen 可能会拦，点 **更多信息 → 仍要运行**。安装包里每个文件的"来自网络"标记，安装脚本已经去掉了。

**3. 安装任务看板（可选）。** 在本仓库的克隆目录里打开 Git Bash，运行和 Mac 一样的命令：

```bash
hq/install.sh --root ~/claude-hq
```

它会先列出要做的每一项改动，问过你才执行。在 Windows 上它还会多做两件事：

- 找一个真正的 Python（先试 `py -3`，再试 `python`）。
- 把 `~/.claude/hq/bin/hq` 写成一个小 sh 脚本，用 UTF-8 运行 `hq.py`，这样中文等文字不会被控制台的代码页弄乱。

任务根目录放在本机，Mac 和 PC 各有各的看板。

**4. 把想在桌宠上看到的 session 重开一次。** hook 是在 session 启动时加载的。

**卸载：** 运行安装包里的 `uninstall.ps1`，它只移除桌宠自己的 hook、程序、可执行文件和数据目录。看板在 Git Bash 里运行 `hq/uninstall.sh`，任务卡保留。

## 能用的

**桌宠**

- 小猫待在屏幕角落，总在最前。点小猫旁边的地方，会点到下面的窗口；小猫可以拖到另一块屏幕。
- 托盘图标的菜单有：显示 / 隐藏、回到角落、Task Board…、点 session 时打开什么（它的终端或它的任务）、语言、开机启动、日志、退出。
- 在 session 列表里可以：
  - **允许**或**拒绝**权限确认；
  - 看完成提示和 **Finished** 分组；
  - 稍后提醒、静音某个 session；
  - 鼠标停在一行上，显示它的详情卡。
- 每一行显示的内容和 Mac 一样：绑定的 HQ 任务、对话轮数、上下文（`210k·70%`）；这一轮结束后它启动的命令还在跑时，显示"后台 N 个"。行名用 Claude Code 里的会话名（`/rename` 起的），没有就用文件夹名。
- 鼠标停在小猫上看额度。需要有状态栏程序把额度存下来，比如 claude-hud，把 `display.externalUsageWritePath` 设成 `%USERPROFILE%\.claude\pet\hud-usage.json`。
- **跳到 session 的终端（↗）：**
  - **Orca** 的标签页；
  - **Windows Terminal** 的标签页（开了好几个也能找到对的那个）；
  - **控制台窗口**（经典窗口里的 PowerShell 或 cmd，最小化了也会恢复）。

**任务看板。** 双击小猫，或者托盘 → **Task Board…**。下面这些都和 Mac 一样能用：

- Focus、项目与职责、Needs you。
- 任务侧栏、session 列表、Peek。
- 在看板上回应确认：允许 / 拒绝、多选题点 **Answer…**、批准计划或写修改意见。
- 在三个地方开新 session、续上旧的：
  - **Windows Terminal** 开一个新标签页；
  - **Orca** 开一个新的 Orca 标签页；
  - **后台** 运行 `claude --bg`。
- 给 session 打字：发消息、**Esc** 中断、**■** 停止。
  - Windows Terminal、控制台窗口和 Orca 都支持。
  - 后台 session 在两轮之间收到消息，看板会带着消息让它接着跑。
  - 文字按粘贴的方式送进去，里面的 `/` 或 `@` 不会弹出补全菜单。
  - 那个标签页不用在最前面。
- 任何 session 里都能用 `/task`、`/board`、`/hq-onboard`。

**手机访问。** 和 Mac 一样，在手机浏览器里用看板。在看板的**设置（⚙）→ 手机访问**里打开，点**配对手机**，用手机扫二维码。配对过的手机也在那里移除。

- **同一个 Wi-Fi 里。** 桌宠监听 8790 端口，并列出这台电脑在局域网里的地址。第一次打开时，Windows 防火墙会问是否允许 ClaudePet 接受连接：勾选**专用网络**并允许。如果 Windows 把这个 Wi-Fi 当成公用网络，要同时允许公用网络，或者把这个 Wi-Fi 改成专用网络，手机才连得上。
- **出门在外，走 Tailscale。** 电脑和手机都开着 Tailscale、登录同一个账号，再勾选**也通过 Tailscale 访问**，点**用 Tailscale 配对**，再配对一次。地址是这台电脑在 Tailscale 里的名字，比如 `http://my-pc.tailxxxx.ts.net:8790`。只放行这台电脑所属 Tailscale 用户自己的设备；在公司的 tailnet 里，同事的设备和带标签的服务器即使连得到这台电脑，也会被拒绝。
- 换端口：在 `%APPDATA%\ClaudePet\prefs.json` 里写 `"boardServerPort": 8791`，再把手机访问关掉重开。

## Windows 上还没有的

- **秘书**、**定时任务**。看板会提示"Windows 版暂不支持"。
- **消息源**（Zulip、Jira）和**自动勾选完成的待办**。它们的凭据放在 macOS 钥匙串里。
- **记一笔的快捷键**（⌃⌥⌘N）。
- **小猫的提醒**，比如额度预警、"上下文快满了"。
- **续上**总是开新标签页，不会复用空闲的标签页。
- **VS Code 里的终端**：那里的 session 没有 ↗。

## 注意事项

- **要用官方安装的 `claude.exe`，不要用 npm 的 `claude.cmd`。** 看板只用 `claude.exe` 开 session。`.cmd` 要经过 cmd.exe，标题或消息里的 `&`、`%…%` 会被它当成自己的语法。在 `node.exe` 下运行的 session（npm 安装的）记不到 Claude Code 的进程，所以那一行不能跳转，也不能发消息。
- **从 Orca 里启动的 Windows Terminal**（在 Orca 的终端里敲 `wt`）会继承 Orca 的环境变量，它里面的 session 会被当成那个 Orca 标签页。请从开始菜单打开 Windows Terminal。
- 安装前就开着的 session 要**重开一次**。
- **小猫没起来、看板打不开时**，看日志：`%APPDATA%\ClaudePet\pet.log`（托盘 → 日志）。

## 从源码构建

需要 Swift 6.1.2 for Windows（加上它要求的 Visual Studio Build Tools）和 Node 20 以上。构建步骤、开发流程、每部分对应 Mac 的哪段代码，都在 [windows/CLAUDE.md](../windows/CLAUDE.md) 里。
