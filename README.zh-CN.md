# Claude Pet

[English](README.md) · **中文**

一只常驻 macOS 桌面的小机器人，坐在电脑前，用动作反映本机全部 Claude Code session 的聚合状态。

<img src="docs/images/pet.gif" width="300" alt="机器人的四种状态">

天线顶上那颗灯是最好认的信号——不用聚焦，余光扫过去就能读到：

![四种状态](docs/images/states.png)

| 状态 | 天线灯 | 它在干嘛 |
|---|---|---|
| 有 session 在干活 | 绿灯慢闪 | 低头敲键盘，屏幕上代码在刷 |
| 有 session 等你授权 | 黄灯脉冲 | 停下手，转过来朝你招手 |
| 等超过 60 秒 | 红灯急闪 | 双手举过头顶，整个人在抖，气泡写出是哪个 project **以及卡在哪条命令上** |
| 全都停了 | 灭 | 趴桌上睡着，头顶飘 zzz，屏幕全黑 |

点它展开 session 列表，拖它换位置，右键暂停或退出。不发系统通知、不出声。

**点列表里带 ↗ 的行，直接跳回那个 session 所在的终端标签页。** 支持 Orca 和 iTerm2：

- **Orca** 走它自带的 CLI（`orca terminal switch`），不需要任何系统权限
- **iTerm2** 走 AppleScript，**第一次跳转会弹一次 macOS 自动化授权**，拒绝之后就静默失效
- 其他终端认不出来，那些行不带 ↗、点了只会展开/收起面板

某个 session 干完一轮活，宠物会立刻说出是哪一个——你不用盯着也知道它停下来了。

session 只要进程还活着就一直列在上面，不管多久没动静——存活是查进程，不是看时间戳。

同一个目录下开了多个 session 时，那几行会各自把 session 名字写在第二行——否则三个 `daily_work` 在列表里长得一模一样。只有一个 session 的目录不受影响，不会平白多占一行。

**鼠标停在某一行 0.45 秒**，气泡显示这个 session 的名字（终端标签的标题）。面板里那列是目录名，同一个仓库开三个 session 长得一模一样——名字才分得清是「客户A回归缺陷跟进」还是「20260916-email reply」。名字只有 Orca 和 iTerm2 的 session 有，而且只在你展开列表时才去查一次。

**停在机器人身上 1 秒**，气泡把额度画成两条进度条——五小时和一周并排，各带倒计时。超过 60% 变黄、超过 85% 变红，和天线灯是同一套预警色。

**不想看某个 session**：鼠标移到那一行，行尾出现 ×，点它静音。静音的 session 既不在列表里，也不会影响宠物表情（它卡在等授权也不会让宠物举手）。**下次你在那个 session 里敲字，它自动回来**，不用手动取消。面板底部会写着还静音着几个，右键菜单可以一次性全部取消。

## 安装

```bash
./scripts/install.sh
```

编译当前工作副本并装到本机。不需要 jq、不需要 Python，只要有 Swift 工具链。

额度播报依赖 [claude-hud](https://github.com/jarrodwatts/claude-hud) 这个 statusline 插件——宠物读的是它维护的 usage 缓存，而不是自己去调 Anthropic 的 usage API，所以不碰你的 OAuth token、也不占你的 rate limit。没装那个插件的话，除了额度以外一切照常。

**这个脚本会改你的 `~/.claude/settings.json`**：往 hooks 里追加八条 `pet-emit`（SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / PermissionRequest / Stop / SessionEnd），已有的 hook 一条不动、一个字节不改。备份、原子写、写完解析校验、出问题回滚都在 `pet-emit --patch-settings` 里做。settings.json 写坏了本机所有 session 都受影响，这是整个项目风险最高的一步，所以备份别删。

装完要开一个新的 Claude Code session 才会生效，已经开着的不受影响。

## 卸载

```bash
./scripts/uninstall.sh
```

摘掉 hook、删掉 app 和开机自启的 plist，`settings.json` 回到装之前的样子。

## 发给别人

```bash
./scripts/package.sh
```

产出两个包：`dist/claude-pet-<版本>.tar.gz` 带预编译 universal 二进制和一键安装脚本，收件人不需要任何开发工具；`dist/claude-pet-<版本>-src.tar.gz` 是纯源码。

## 开发

```bash
swift run ClaudePetTests     # 单元测试（不是 swift test，本机没装 Xcode）
./hooks/test-pet-emit.sh     # hook 行为测试
./scripts/build-app.sh       # 只打包 ClaudePet.app，不安装
```

形象预览（四个状态的动画，浏览器里直接看）：`docs/previews/coder-pet.html`

设计文档在 `docs/superpowers/specs/`，讲清楚了架构，以及每个地方为什么是现在这样。

终端跳转的逻辑分两半：能纯粹测的（识别终端、解析 session id、防 AppleScript 注入）在 `Sources/ClaudePetCore/TerminalTarget.swift`，真正执行跳转的在 `Sources/ClaudePet/TerminalJump.swift`。

宠物的点击命中区是 `Sources/ClaudePetCore/PetLayout.swift` 里的两个矩形，和 `Resources/pet/pet.css` 的画面必须对齐——**改了画面就要改 PetLayout，反之亦然**。这一点没有测试能替你发现（测试只能锁住 Swift 那一半），只能靠这条约定。

## License

MIT，见 [LICENSE](LICENSE)。
