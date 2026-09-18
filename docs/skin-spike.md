# 换皮肤这件事：探针结果和计划

分支 `dev/pet-skins`，不打算合主干，先看效果。

素材来源：`~/Downloads/cat-pet-animation-kit`（橘猫程序员 v0.1，五张 1254² 透明 PNG
加一个 WebGL 形变播放器）。

## 量出来的结论

探针是 `Sources/ClaudePet/SkinProbe.swift` 加 `--probe-skin <page> <png>`，在跟真窗口
同样配置的 WKWebView 里跑（`drawsBackground` 为 false、borderless、非 opaque、
floating），用 `takeSnapshot` 出图——这样不需要录屏权限。

| 问题 | 结果 |
| --- | --- |
| WebGL 能不能跑 | 能，renderer 是 `Apple GPU` |
| 透明合成有没有黑边 | 没有。把猫压在品红色块上截图看的，`premultipliedAlpha:false` 最典型的毛病就是描边发黑 |
| file:// 单独贴图 | **卡死**。见下 |
| 贴图体积 | 12MB → 384² 八叉树量化后五张共 128KB |
| CPU（WebContent 进程，稳定态） | 猫 0.00%，SVG 机器人忙碌打字 0.40% |
| 内存（RSS） | 猫 41MB，机器人 34MB |

CPU 是同一套探针交替测两轮、每轮 10 秒，取 `ps -o time` 的差值而不是 `%cpu`（那是
生命周期均值）。0.00% 的意思是低于 `ps` 的 0.01 秒分辨率，也就是 10 秒里不到 0.1%。
猫反而更省，因为形变跑在 GPU 上，而 SVG 机器人那一堆元素的动画是 CPU 在算。

**没量的：GPU 功耗。** 一个常驻屏幕、一直在提交帧的 GPU surface，在电池上的代价 CPU
时间看不出来。正式做之前要用 powermetrics 看一眼。

## 唯一的硬前提：贴图不能走 file://

第一次探针跑出来是个空壳——灯和角标都在，猫没有。原因是 WKWebView 下每个 file://
文件是独立 origin，`texImage2D` 上传一张来自另一个 file 的图会抛安全异常，而这个异常
是在 `img.onload` 里抛的，播放器的 promise 既不 resolve 也不 reject，**静默挂住**。
改成内联 data URI 立刻就出来了。

正式做要挂一个 `WKURLSchemeHandler`（比如 `pet://`），让整个页面和贴图在同一个 origin
下。这条不解决，功能第一步都迈不出去，而且它的症状是"什么都不显示、没有报错"——最难查
的那一类。

## 状态映射：11 → 5

宠物现在有 11 个状态（README 那张表），猫有 5 个。

| 宠物 | 猫怎么表现 | 靠什么区分 |
| --- | --- | --- |
| busy / editing | `working` | |
| busy / reading | `working` | 三种姿势并成一种，只有灯的绿在分 |
| busy / running a tool | `working` | |
| compacting | `working` | 灯：绿灯常亮 |
| awaiting-agent | `working` | 灯：绿灯慢脉冲 |
| tool interrupted | `working` + 宿主画的警告三角 | 没有专门贴图，但符号补上了 |
| wants approval | `waiting` + 宿主画的警告三角 | |
| wants an answer | `waiting` + 宿主画的问号 | 同一张举爪图，符号区分 |
| ignored 60s+ | `urgent` | 贴图自带红色警告 |
| turn finished | `idle` + 渲染器的一次弹跳 | 没有专门贴图，用形变代替 |
| idle | `idle` | 有未读完成时 |
| 全都停了 | `sleeping` | |

一开始是「11 个状态只有 5 张图，丢 6 个」。后来发现丢掉的里有三个**不需要新素材**：

- **问号原本画死在 `waiting.png` 里**，而它是一个跟猫身完全不相连的连通域（46095
  像素）。抠掉之后那张图变成通用的「举爪」，问号和警告三角改由宿主层画——一张图
  同时服务「等你回答」和「等你授权」，而这两个原本是共用一张图、都顶着问号的，
  等授权顶问号是错的（问号的意思是「我不确定」，授权的意思是「你来定」）。
- **工具被打断**同理：`working` 加宿主画的警告三角。机器人在这个状态也就是显示器转
  黄、人继续干活，是同一个语汇。
- **刚干完一轮**没有贴图，也不该有——它是个 1.6 秒的瞬态，一张静止图说不出「刚
  刚」。改成让渲染器把 `idle` 那张图弹一下，脚不动、头抬起约 2.9pt，0.12 秒到顶，
  1.2 秒衰减干净。

真正还缺素材的只剩四个 busy 变体（读代码 / 等命令 / 压缩上下文 / 等后台 agent），
它们要的是不同的身体姿势，加符号解决不了。但这四个是「说得没那么细」不是「说不
出来」，灯已经把它们分开了。

## 架构：皮肤画角色，宿主画信号

README 第一句是「The lamp is the signal——不用聚焦就能读」。猫身上没有灯，120pt 大小
在余光里，橘猫打字和橘猫招手区分不出来。

探针里试的解法是把灯、角标、气泡全留在 HTML/CSS 层，画在 canvas 上面，位置跟皮肤无关
（截图里那个绿点和红角标就是这么画的）。这样换皮肤只换"人"，信号一条不丢，丢的只是
姿势的细分。

## 影响面

要改：

- `Resources/pet/index.html` / `pet.css` / `pet.js`：`#pet` 从写死的 SVG 变成插槽，加一层
  皮肤适配器，把 `data-mood` / `data-motion` / `data-phase` / `data-flash` 翻译成 `setState`
- `PetLayout.swift` 的两个命中矩形：猫的轮廓跟机器人完全不一样（机器人是宽扁的桌子，猫是
  竖的），要按皮肤分别给。README 里写过这里没有测试能抓到不一致，只能画出来看
- 一个设置项加右键菜单，照 `globalShortcutEnabled` 那套
- `WKWebViewConfiguration` 加 scheme handler
- 打包多 128KB

**不动：hooks、PetEmit、状态聚合、面板、完成队列、额度、终端跳转。** 这些全在绘制层下面，
一行不用改。爆炸半径就一层。

## 待定

1. 丢掉的 6 个状态怎么办。尤其"刚干完一轮"——要么接受猫不报完成（只剩角标和气泡），
   要么让宿主层的灯兜住，要么回头补贴图。
2. 猫 waiting 那张的问号是画死的，"等授权"用它会一直显示问号，那是错的。要么接受，要么
   把问号拆出来交给宿主层画。

## 探针留下来了

spike 时打算用完就删，做完决定留着：这个项目里「图和命中矩形对不对得上」是测试结构上
抓不到的（README 里专门写了这条，镜像布局那次就是所有测试全绿、天线还是在命中区外面），
只能画出来看。皮肤系统把这个面翻倍，所以把「看」做便宜比把探针删掉值。

    ClaudePet --probe-skin index.html /tmp/cat.png 'window.setSkin("cat")'

把真页面渲染成 PNG，走真的 `pet://` 加载路径，不需要录屏权限。两张临时探针页
（`probe-robot.html`、`skins/cat/probe.html`）已经删了，它们的活现在由 `--probe-skin`
的第三个参数干。

## 还缺的素材

四个 busy 变体：读代码（凑近屏幕）、等命令跑完（盯着屏幕）、压缩上下文（整理桌面）、
等后台 agent（托腮看屏幕）。对生成那边的技术要求（1254² 透明 PNG、底边统一在画布
97~98% 处、画布左上角留白、符号单独出图层）见 PR 描述。

**符号从此不用画进贴图。** 宿主层已经能画灯、角标和符号，所以以后加一个状态多半只要
加一个符号，不用重新生成整只猫。这条是这次最值钱的收获。
