# Claude Pet

一只常驻 macOS 桌面的小机器人，坐在电脑前，反映你本机**所有** Claude Code session 的状态。

不用再一个个窗口翻过去看哪个跑完了、哪个卡住了——余光扫一眼桌面就知道现在要不要管。

天线顶上那颗灯是最好认的：不用聚焦，颜色变了你就知道。

| 天线灯 | 它在干嘛 | 什么意思 |
|---|---|---|
| 红灯急闪 | 双手举过头顶在抖，头顶冒气泡 | 有 session 卡着等你授权，超过 60 秒了。气泡上写着是哪个 project |
| 黄灯脉冲 | 停下手，转过来朝你招手 | 有 session 在等你授权 |
| 绿灯慢闪 | 低头敲键盘，屏幕上代码在刷 | 有 session 在干活 |
| 灭 | 趴桌上睡着，头顶飘 zzz | 全都停了 |

**左键点它**展开列表，看每个 session 在忙什么、多久了。
**点列表里带 ↗ 的行**，直接跳回那个 session 所在的终端标签页（支持 Orca 和 iTerm2）。
同一个目录下开了多个 session 时，那几行会各自把名字写在第二行，否则它们在列表里长得一模一样。
**鼠标停在某一行**，气泡显示这个 session 的名字（终端标签的标题），因为列表里那列只是目录名，同一个仓库开几个 session 是分不出来的。**停在机器人身上**则显示额度还剩多少、什么时候回血。
**鼠标移到某一行，点行尾的 ×** 把它静音——不在列表里显示，也不影响宠物表情。下次你在那个 session 里敲字它自动回来。
**右键**出菜单：暂停 / 开机自启 / 退出。
**拖动**换位置，会记住。

它不会响，也不发系统通知——只在你余光里变化，不打断你。

## 装

```bash
./install.sh
```

装完**要开一个新的 Claude Code session 才生效**，已经开着的窗口不受影响。

## 前提

- macOS 14 或更新
- 已经装了 Claude Code

不需要 Xcode、不需要 Python、不需要 jq。包里是编译好的 universal 二进制，Intel 和 Apple Silicon 都能跑。

## 它会动你机器上的什么

就三个地方，`uninstall.sh` 都能还原：

1. `~/Applications/ClaudePet.app` —— 宠物本体
2. `~/.claude/pet/` —— hook 程序和 session 状态文件
3. **`~/.claude/settings.json` —— 追加 8 条 hook**

第三条是唯一需要留心的：那个文件管着你所有 Claude Code session 的行为。安装脚本的做法是**只追加、不修改**——你已有的 hook 配置一条都不会被碰，改之前会自动备份到 `~/.claude/settings.json.bak-claudepet-<时间戳>`，改完立刻解析验证，任何异常都会自动还原备份。重复安装是幂等的，不会挂两遍。

宠物读的是 `~/.claude/pet/sessions/` 下的状态文件，只记录 project 名、当前状态、工具名和时间戳。**不读你的对话内容，不联网，什么都不上传。**

## 卸

```bash
./uninstall.sh
```

摘掉 hook、删掉 app、清理目录。`settings.json` 会回到装之前的样子（备份文件留着，你确认没问题可以自己删）。

## 已知的几个毛病

- 展开的面板固定往左边开。宠物拖到屏幕最左边时面板会跑出屏幕外（宠物本身不会丢）
- 点击穿透按两个矩形算（机器人和桌子一块、天线一块），不是严格按轮廓。这两块矩形里看着是空白的地方也点不到底下的窗口
- idle 时大约占 4% CPU（是那个呼吸动画），24 小时挂着会有一点耗电
- 没有 Apple 开发者签名。安装脚本会自动清掉 macOS 的下载隔离标记；万一还是被拦，去「系统设置 → 隐私与安全性」点一下允许就行

## 出问题了

**宠物一直打瞌睡，明明有 session 在跑**
hook 只对**新开的** session 生效。开一个新窗口试试。还是不行就看 `~/.claude/pet/sessions/` 里有没有文件在生成。

**关掉的 session 还在列表里**
不该发生了：现在是查那个 session 的进程还在不在，关掉就立刻消失，直接叉掉终端窗口也一样。如果真遇到，多半是那条状态文件是升级前留下的（没记进程号），在那个 session 里随便发一条消息就会补上。

**行右边没有 ↗，点了不跳转**
只有 Orca 和 iTerm2 能跳。另外升级前就开着的 session 也没有，在那个 session 里发一条消息就会补上。

**点 iTerm2 的行没反应**
第一次跳转 macOS 会弹一次授权框问你要不要允许 ClaudePet 控制 iTerm2，拒绝了就会一直静默失败。去「系统设置 → 隐私与安全性 → 自动化」把 ClaudePet 下面的 iTerm 勾上。Orca 不需要这个授权。

**想临时让它闭嘴**
右键 → 让宠物睡一会。要单独屏蔽某个 session，鼠标移到那一行点 ×。

**静音的 session 怎么找回来**
在那个 session 里随便说句话就回来了。或者右键 → 取消静音（会全部取消）。

**找不到怎么退出**
右键 → 退出。它不在 Dock 也不在 Cmd-Tab 里（故意的，免得占位置），右键菜单是唯一入口。实在不行 `pkill -x ClaudePet`。

## 源码

包里的 `src/` 就是完整源码。自己编：

```bash
cd src
./scripts/build-app.sh release          # 本机架构
./scripts/build-app.sh release universal # Intel + Apple Silicon 通吃
swift run ClaudePetTests                 # 单元测试（不是 swift test，不依赖 Xcode）
./hooks/test-pet-emit.sh                 # hook 行为测试

# 形象预览（四个状态的动画，浏览器里直接看）
open docs/previews/coder-pet.html
```
