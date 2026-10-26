# 用 Seedance 给猫做逐帧动画

一个视频里上、中、下三只猫各做各的动作，循环类视频再用 10 秒装下「循环 + 小动作」两段。
31 段动画一共 **8 个视频**。

```bash
swift scripts/cat-seeds.swift                 # → art/seedance/sheets/
# …在 Seedance 里生成 8 个视频，存成 art/seedance/videos/<表名>.mp4
scripts/cat-frames.sh art/seedance/videos     # → Resources/pet/skins/cat/frames/
swift build && .build/debug/ClaudePet         # 或 ./scripts/install.sh
```

`art/` 不进 git。要蓝底：`swift scripts/cat-seeds.swift art/seedance/sheets blue`（抽帧时
自动从画面四边判断是绿幕还是蓝幕）。

## 每个视频怎么生成

`art/seedance/sheets/` 里每张表三个文件：

| 文件 | 用途 |
| --- | --- |
| `<表名>-first.png` | 首帧 |
| `<表名>-last.png` | 尾帧（循环表跟首帧是同一张图） |
| `<表名>.txt` | 提示词，整段复制 |

| 项 | 设置 |
| --- | --- |
| 模式 | 图生视频 · **首尾帧** |
| 比例 | **9:16**（三只猫竖着排，别的比例会切错，抽帧会警告） |
| 分辨率 | 720p 足够（每只猫最后缩到 240px） |
| 时长 | 按下表；生成成别的时长也能用，切点按比例换算 |
| 镜头 | 固定 |

| 表名 | 时长 | 上 | 中 | 下 |
| --- | --- | --- | --- | --- |
| `calm` | 10s | sleeping | idle | awaiting-agent |
| `busy` | 10s | working | reading | compacting |
| `alert` | 10s | waiting | urgent | finished |
| `to-working` | 5s | sleeping→working | idle→working | waiting→working |
| `from-working` | 5s | working→finished | working→waiting | working→idle |
| `settle` | 5s | finished→idle | idle→sleeping | waiting→urgent |
| `to-task` | 5s | working→reading | working→compacting | working→awaiting-agent |
| `from-task` | 5s | reading→working | compacting→working | awaiting-agent→working |

**先做前三个**：9 个姿势全都动起来，外加 9 个小动作。过渡没有也行，播放器会用 0.15 秒
淡入淡出代替。

### 只能上传一张图的工具（豆包）

豆包里的 Seedance 没有首尾帧选项。在提示词里写「第二张图是结尾」没用：多传的图只会被
当成角色参考，不会被当成最后一帧。那就只传 `-first.png`，靠抽帧来补：

- **循环表照做，基本不受影响。** 首帧是钉死的；结尾回不到原位，抽帧会在最后 1.5 秒里挑
  最像第一帧的那一刻收尾，后面的扔掉。提示词里已经要求最后一秒回到原位。
- **过渡表会受影响。** 终点姿势全靠模型照文字去画，画出来的书、电脑位置跟终点那张图对
  不上，接到终点的循环时会跳一下。先用豆包试一张 `to-working`，看抽帧打的接缝分；跳得
  明显，就用即梦（同一个 Seedance，有首尾帧）做这五张，或者干脆不做过渡，用淡入淡出。

抽帧会给每一段打**接缝分**（首尾帧和该接上的姿势差多少）：0.02 以下看不出来，超过 0.04
会标 ⚠，那段值得重抽。

拿到视频先看三件事，不合格就重抽：背景是否一直是纯绿；三只猫有没有离开自己那一行、
变大变小或者互相学动作；最后一帧是不是回到了尾帧图。

## 为什么这么排

**首尾帧把接缝钉死。** Seedance 只保证第一帧和最后一帧，中间是它自由发挥。循环表首尾是同
一张图，所以 10 秒结尾一定回到初始姿势；过渡表首帧是起点姿势、尾帧是终点姿势，所以过渡
一定落在终点那个循环的第一帧上。所有片段的接缝都在这 9 张种子图上，可以任意拼接。

**中间的切点靠找，不靠秒数。** 循环表让猫「0-5 秒循环动作、第 5 秒回到初始姿势、5-10 秒
做个小动作」，但第 5 秒那一下模型不保证。抽帧时会在 4~6 秒里找最像种子图的那一帧切开，
循环就切在猫真正回来的那一刻。过渡同理：在 2~4 秒里找最像终点姿势的那一帧收尾，首尾一动
不动的帧再剪掉，最后压到 1.5 秒以内。

**过渡表只用 5 秒。** 过渡只有 3 秒是有用的，后 2 秒只是让模型落稳到尾帧图上，切的时候
扔掉。如果你的额度是按条数而不是按秒数算，可以改成 10 秒，再在
`scripts/cat-sheets.json` 里把后半段从 `skip` 改成小动作。

**一张表里的三只猫都要指名道姓。** 模型最常犯的错是让三只猫做一样的动作，所以提示词按
「上方的猫 / 中间的猫 / 下方的猫」分开写，并且明确说动作互不同步。

## 改动作

动作、秒数、切法都在 `scripts/cat-sheets.json`。改完重跑 `cat-seeds.swift`，提示词就跟着
变。片段名的规则：`<姿势>` 是循环，`<姿势>@<名字>` 是小动作，`<起>_to_<止>` 是过渡。播放器
在一个姿势里待满 8 秒后，每播完一圈循环有约三分之一的机会插一段小动作；两个姿势之间没有
直接过渡时，如果 `A_to_idle` 和 `idle_to_B` 都有，会经过 idle 走过去。

## 拿到视频之后

每次都对整个目录跑 `scripts/cat-frames.sh art/seedance/videos`。这是全量重建：删掉的视频，
对应的帧也会被删。它会打印每段剪成了几帧、多长，缺的视频会写 `no video yet`。抠像有绿边
或者缺块，把那段视频发我看，阈值在 `cat-frames.swift` 的 `key()` 里。

体积参考：一段 5 秒循环约 1.5MB（JPEG 颜色 + PNG 透明度两张图集），一段过渡约 0.5MB，
整套二十几 MB。
