# 开发

[English](development.md) · **中文** · [← README](../README.zh-CN.md)


```bash
swift run ClaudePetTests     # 单元测试（不是 swift test，本机没装 Xcode）
./hooks/test-pet-emit.sh     # hook 行为测试
./hooks/test-settings-patch.sh  # settings.json 往返测试，见下
./scripts/build-app.sh       # 只打包 ClaudePet.app，不安装
```

`PET_DUMP=/tmp/hooks.jsonl claude` 会让 hook 程序把收到的每个 payload 原样追加到这个文件，
不设这个变量就什么都不做。这是调试工具不是功能——payload 里带着 prompt 原文——但想知道某个
hook 到底发了什么，只有这一条老实路子。这里靠猜错过不止一次：早先那版额度解析列了五种它觉得
可能的字段拼法，恰好漏掉真的那个，于是什么都没读到，README 上还写着「未验证」。

想看所有状态动起来：在仓库根目录跑 `python3 -m http.server 8777`，然后开
`http://127.0.0.1:8777/docs/previews/`。旁边的 `cycle.html` 就是 README 那张动图的来源。
两个页面都是直接把真的 `Resources/pet/index.html` 嵌进去、不另存一份，而且上面那两张图
也都从这两个页面截出来——一件事只留一份产物，文档才不会比代码少一个状态，上一版的状态图
就是这么漏掉的。

设计文档在 `docs/superpowers/specs/`，讲清楚了架构，以及每个地方为什么是现在这样。

终端跳转的逻辑分两半：能纯粹测的（识别终端、解析 session id、防 AppleScript 注入）在 `Sources/ClaudePetCore/TerminalTarget.swift`，真正执行跳转的在 `Sources/ClaudePet/TerminalJump.swift`。

`settings.json` 的补丁测试跑的是真文件，不是进程内单测。因为这是这个项目唯一能把别人机器搞坏的地方，而它危险的部分——备份、原子写、写完解析回读、出事回滚——全都只存在于磁盘上，在内存里测等于没测。断言里最要紧的一条是往返：装上再卸掉，用户自己的 hook 一个字段都不能变。

宠物的点击命中区是 `Sources/ClaudePetCore/PetLayout.swift` 里的一个矩形，和 `Resources/pet/pet.css` 的画面必须对齐——**改了画面就要改 PetLayout，反之亦然**。这一点没有测试能替你发现（测试只能锁住 Swift 那一半），只能靠这条约定。

这不是假设。镜像布局第一版写成整窗反射（`x → width - maxX`），测试全绿、截图里 body 框也罩得好好的——因为它在 pet 元素里恰好左右对称；不对称的那块命中区直接跑到画面外面去了。抓到它的办法是把命中框画到渲染出来的页面上看一眼。这里改完就这么验一次。

README 里任务看板的截图和动图由 `scripts/board-shots.sh` 生成：它用虚构的演示数据（`docs/previews/board-demo.js`，不会出现任何人的真实任务）渲染真实的看板页面，写出 `docs/images/board-*.png` 和 `board-asks.gif`。看板外观变了就在 `swift build` 之后重跑一次。
