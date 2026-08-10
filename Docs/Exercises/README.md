# 动作库 · 待评审清单

issue [#7](https://github.com/zjywill/HealthChat/issues/7) 的 T1/T2 产物。**只是一份评审材料,
app 里没有它的入口**,也没有进 `project.yml`。

打开 `index.html` 看:46 个动作,每条有图、中文步骤、要领和「什么情况别做」。按场景可筛。

```
Docs/Exercises/
├─ index.html        评审页(自包含,直接双击打开)
├─ exercises.json    数据(将来进 app 的就是这一份的形状)
├─ assets/           59 个 SVG
└─ tools/            生成脚本,改完 moves.py 跑一次 build.py
```

## 三条硬约束

写每一条的时候都照着来的,和 issue #7 里定的一致:

1. **不给次数、组数、保持秒数**——强度按感觉走,同「剂量一律不给建议」那条线。
2. **每条都要有「什么情况别做」**。
3. **步骤写给没练过的人看**,不用「骨盆后倾」这种词。

中文全部人工写,不是机翻。`hasaneyldrm/exercises-dataset`(MIT)那份中文步骤只当参考——
它里面带着「保持拉伸 20-30 秒」这类强度处方,正是第 1 条不许出现的东西。

## 图片来源与授权

已经查清,**没有阻塞项**。

| 来源 | 授权 | 用了几张 | 怎么落实 |
|---|---|---|---|
| [`everkinetic/data`](https://github.com/everkinetic/data) | CC BY-SA 4.0 | 28(14 个动作 × 两态) | 「关于」页列出处和作者 |
| [dDara「Yoga poses」@ Flaticon](https://www.flaticon.com/packs/yoga-poses-6) | Flaticon 免费档(署名)或订阅档(免署名) | 31 | **自己持证下载**,不走 yoga-api 的转授 |

那 31 张是经 [`alexcumplido/yoga-api`](https://github.com/alexcumplido/yoga-api) 找到的。
作者在 [issue #4](https://github.com/alexcumplido/yoga-api/issues/4) 里说明:图不在 MIT 覆盖范围内,
粉/绿两套是他从 Flaticon 买的、他不持有版权。而 dDara 那个包正好 48 个图标、yoga-api 正好 48 个体式
——对得上。**所以直接从 Flaticon 拿我们自己的授权就干净了**,顺带也没有了「随公开仓库再分发」这个灰区。
唯一限制:Flaticon 禁止拿这些图做 AI 生成或风格迁移。

评估过但**一张没用**的:Gym visual(`hasaneyldrm/exercises-dataset` 的 GIF,要单独买且只有 180×180)、
RepDB(禁止随仓库再分发,拉伸全是要弹力带的)、`asanakit` 火柴人渲染(折叠类姿势糊成一团、
正反分不出来,已砍,见 issue #7 评论)。

## 还差什么

- **覆盖缺口**:颈肩只有 5 条、平衡只有 1 条;**手腕前臂、坐姿椅子操、有氧心肺三类完全没有**。
  `tools/needed.py` 是一份**出图清单**——22 个动作、36 张图,每条标了画什么、什么视角、要几张,
  页面最下面那张表就是它。文字都写好了,缺的只是图。
- **两套图风格不一致**:yoga-api 是彩色人物,everkinetic 是单色解剖线稿(偏健美风,对这个 app 里
  那部分年纪大的用户不太对味)。最终要统一成一套。

**没有图的动作不进库**,所以清单上这 22 条现在一条都不在 app 里。补图之后在 `moves.py` 里
写上步骤/要领/禁忌,跑一次 `build.py` 就进去了。

生成图时两条硬约束:**不要拿 dDara 那套当参考图或垫图**(Flaticon 禁止把素材用于生成式 AI);
生成完先看一眼姿势对不对——画错关节角度的图比没有图更糟,用户会照着做。

## app 里的实现

`HealthChat/Exercises/`:`ExerciseLibrary`(载入打进包里的 `exercises.json`)、`ExerciseTools`
(`suggest_exercises` 能力)、`ExerciseCards`(回复下面那排卡)。SVG 走
`HealthChat/Exercises/Exercises.xcassets`,由 `tools/make_assets.py` 从 `assets/` 生成。
`HealthChatTests/ExerciseTests` 盯着这一套。

## 重新生成

```bash
python3 Docs/Exercises/tools/build.py
```

`tools/moves.py` 是动作清单本身(中文步骤都在里面),`tools/build.py` 负责拷素材、写
`exercises.json` 和 `index.html`。素材从上游仓库下载后缓存在脚本目录,脚本里有下载地址。
