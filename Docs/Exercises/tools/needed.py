# 待补动作 · 出图清单。
#
# 这些动作**文字已经写得出来,缺的只是图**——而没有图的动作不进库(见 moves.py 第 4 条),
# 所以它们现在一条都不在 app 里。每一条都标了画什么、什么视角、要几张,照着生成就能补齐。
#
# 两条硬约束:
#   1. **不要拿 dDara 那套图当参考图或垫图。** Flaticon 的条款明确禁止把它们的素材用于
#      生成式 AI(风格迁移、图生图、微调都算)。要接近那个观感只能凭文字描述独立生成。
#   2. 生成完先当成草稿看一眼**姿势对不对**——一张画错关节角度的图,比没有图更糟:
#      用户会照着做。

# 每条:id / 中文名 / 场景 / 画什么(生成提示的要点)/ 视角 / 要几张
# 张数 2 表示这个动作要起始态和结束态两张,卡片上交叉淡入;1 表示一个静态保持的姿势。
NEEDED = [
    # ---- 颈肩:现有 5 条,是最常被问到的一类,太少 ----
    dict(id="wall-angels", zh="靠墙天使", scene="颈肩",
         draw="背贴墙站立，双臂贴墙从 W 形向上滑到 Y 形，肘和手背始终贴墙", view="正面", shots=2),
    dict(id="doorway-chest", zh="门框胸部拉伸", scene="颈肩",
         draw="前臂贴在门框上，肘略低于肩，身体向前迈半步把胸口打开", view="四分之三", shots=1),
    dict(id="scapular-squeeze", zh="肩胛后缩", scene="颈肩",
         draw="坐姿，双肘弯曲向后拉，两侧肩胛骨向中间夹紧，胸口打开", view="四分之三偏后", shots=2),
    dict(id="neck-rotation", zh="颈部左右转", scene="颈肩",
         draw="坐姿，肩不动，头缓慢向一侧转到看肩膀的方向", view="正面", shots=2),

    # ---- 手腕前臂:整类都没有,而这个 app 的用户天天在打字 ----
    dict(id="wrist-flexor", zh="腕屈肌拉伸", scene="办公室",
         draw="一臂前伸肘伸直，掌心朝外指尖朝下，另一只手轻轻把手指往身体方向带", view="侧面", shots=1),
    dict(id="wrist-extensor", zh="腕伸肌拉伸", scene="办公室",
         draw="一臂前伸肘伸直，手背朝上手指朝下，另一只手轻轻下压手背", view="侧面", shots=1),
    dict(id="finger-fan", zh="手指张合", scene="办公室",
         draw="手部特写：从松松的握拳到五指完全张开", view="手部特写", shots=2),

    # ---- 坐姿椅子操:年纪大的用户和办公室场景里最实用的一档,现在完全没有 ----
    dict(id="sit-to-stand", zh="扶椅起立", scene="力量",
         draw="从椅子上坐着到站直，手轻扶椅子扶手，背保持直", view="侧面", shots=2),
    dict(id="seated-leg-extension", zh="坐姿抬腿伸膝", scene="力量",
         draw="坐在椅子上，一条腿从屈膝伸直到与地面平行", view="侧面", shots=2),
    dict(id="seated-marching", zh="坐姿踏步", scene="有氧",
         draw="坐在椅子上，交替把膝盖抬离座面，像原地走路", view="正面", shots=2),
    dict(id="chair-calf-raise", zh="扶椅提踵", scene="力量",
         draw="手扶椅背站立，脚跟抬起用前脚掌支撑再落下", view="侧面", shots=2),
    dict(id="seated-twist-chair", zh="坐姿扶椅转体", scene="办公室",
         draw="坐在椅子上，一手扶椅背一手扶膝，上半身向后转", view="四分之三", shots=1),

    # ---- 平衡:现有只有 1 条,而防跌倒是年纪大的用户最该练的 ----
    dict(id="single-leg-stand", zh="扶椅单腿站", scene="平衡",
         draw="手轻扶椅背站立，一只脚离地，另一条腿站稳", view="正面", shots=1),
    dict(id="tandem-walk", zh="脚跟对脚尖走", scene="平衡",
         draw="沿一条直线走，后脚的脚尖顶着前脚的脚跟", view="正面", shots=2),
    dict(id="side-step", zh="扶椅侧向踏步", scene="平衡",
         draw="手扶椅背，双脚交替向一侧跨步再并拢", view="正面", shots=2),
    dict(id="weight-shift", zh="左右重心转移", scene="平衡",
         draw="双脚与髋同宽站立，把身体重心缓慢从一只脚移到另一只脚", view="正面", shots=2),

    # ---- 有氧心肺:整类都没有 ----
    dict(id="marching-in-place", zh="原地踏步", scene="有氧",
         draw="站立原地交替抬膝，手臂自然摆动", view="正面", shots=2),
    dict(id="side-tap", zh="原地侧点步", scene="有氧",
         draw="站立，一只脚向侧点地再收回，双手随之抬起——开合跳的低冲击版本", view="正面", shots=2),
    dict(id="brisk-walk", zh="快走", scene="有氧",
         draw="正常快走的一个瞬间，手臂前后摆动，步幅比散步大", view="侧面", shots=1),

    # ---- 补几条零散的 ----
    dict(id="behind-back-clasp", zh="背后交扣扩胸", scene="颈肩",
         draw="站立，双手在身后十指交扣，手臂伸直向下向后，胸口打开", view="四分之三", shots=1),
    dict(id="puppy-pose", zh="跪姿伸展（小狗式）", scene="腰背",
         draw="跪姿，手臂向前伸直贴地，胸口向下沉，髋保持在膝盖正上方", view="侧面", shots=1),
    dict(id="calf-wall", zh="扶墙小腿伸展", scene="跑后",
         draw="面对墙双手扶墙，一脚后撤伸直脚跟踩地，前膝弯曲身体前压", view="侧面", shots=1),
]

# 出图规格。命名对上之后,把文件丢进 tools/gen_svg/ 再跑一次 build.py 就进库了。
SPEC = dict(
    style="扁平彩色矢量插画，单人，线条干净，无背景装饰、无文字、无器械品牌",
    palette="肤色 + 一两件素色衣服；避免高饱和；深浅色模式下都要看得清",
    canvas="正方形，人物占画面约 80%，四周留一点空",
    fmt="优先 SVG（跟着字号缩放不糊）；PNG 的话至少 1024×1024，透明或纯白底",
    naming="gen-<id>-a.svg / gen-<id>-b.svg（只要一张时就只有 -a）",
    orientation="视角按每条标的来。正反一定要分得出来——这正是火柴人那条路被砍掉的直接原因",
)
