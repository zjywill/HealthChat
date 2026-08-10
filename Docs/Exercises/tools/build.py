#!/usr/bin/env python3
# 生成 Docs/Exercises/{index.html,exercises.json,assets/}
#
# 素材已经缓存在 tools/yoga_svg 和 tools/ek_svg 里。要重新拉的话:
#   yoga_svg/<id>.svg   ← alexcumplido/yoga-api 的 db/database.db,poses 表的 url_svg 字段
#   ek_svg/<id>-{tension,relaxation}.svg
#       ← https://raw.githubusercontent.com/everkinetic/data/master/dist/svg/<id>-<state>.svg
import json, os, shutil, sys, html

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from moves import MOVES as ALL_MOVES
from needed import NEEDED, SPEC

# 没有图的不进库:一条只有文字的卡片,正是模型不用这个库也能写出来的东西。
# 丢掉几条要说出来,不静默截断。
MOVES = [m for m in ALL_MOVES if m["img"]]
if len(MOVES) != len(ALL_MOVES):
    print("跳过没有图的:", [m["id"] for m in ALL_MOVES if not m["img"]])

OUT = os.path.dirname(HERE)
ASSETS = os.path.join(OUT, "assets")

SOURCES = {
    "yoga": dict(
        name="alexcumplido/yoga-api",
        url="https://github.com/alexcumplido/yoga-api",
        license="图片授权待确认(见 README)",
        style="彩色线稿,单张静态",
    ),
    "ek": dict(
        name="everkinetic/data",
        url="https://github.com/everkinetic/data",
        license="CC BY-SA 4.0",
        style="线稿,tension / relaxation 两态",
    ),
}

os.makedirs(ASSETS, exist_ok=True)
for f in os.listdir(ASSETS):
    os.remove(os.path.join(ASSETS, f))

# 拷贝素材,文件名前面加来源,免得两个源撞名
for m in MOVES:
    files = []
    for fn in m["img"]:
        src_dir = "yoga_svg" if m["src"] == "yoga" else "ek_svg"
        dst = f"{m['src']}-{fn}"
        shutil.copyfile(os.path.join(HERE, src_dir, fn), os.path.join(ASSETS, dst))
        files.append(dst)
    m["files"] = files

SCENES = ["颈肩", "腰背", "髋腿", "核心", "力量", "睡前", "跑前", "跑后", "办公室", "平衡"]

with open(os.path.join(OUT, "exercises.json"), "w", encoding="utf-8") as f:
    json.dump({"version": 1, "sources": SOURCES, "scenes": SCENES,
               "moves": [{k: v for k, v in m.items() if k != "img"} for m in MOVES]},
              f, ensure_ascii=False, indent=1)


def e(s):
    return html.escape(s or "")


cards = []
for i, m in enumerate(MOVES):
    tags = "".join(f'<span class="tag">{e(t)}</span>' for t in m["scenes"])
    steps = "".join(f"<li>{e(s)}</li>" for s in m["steps"])
    imgs = "".join(
        f'<img src="assets/{e(fn)}" alt="{e(m["zh"])} 图 {j + 1}"'
        f'{" class=\'b\'" if j else ""}>' for j, fn in enumerate(m["files"]))
    two = " two" if len(m["files"]) > 1 else ""
    fig = f'<div class="fig{two}">{imgs}</div>'
    src = SOURCES.get(m["src"], {}).get("name", "—")
    cards.append(f"""<article class="card" data-scenes="{e(' '.join(m['scenes']))}">
 {fig}
 <div class="body">
  <h3>{e(m['zh'])}<span class="en">{e(m['en'])}</span></h3>
  <div class="tags">{tags}</div>
  <dl class="meta"><dt>部位</dt><dd>{e(m['part'])}</dd><dt>器械</dt><dd>{e(m['gear'])}</dd></dl>
  <ol class="steps">{steps}</ol>
  <p class="cue"><b>要领</b>{e(m['cue'])}</p>
  <p class="avoid"><b>什么情况别做</b>{e(m['avoid'])}</p>
  <p class="src">图:{e(src)}</p>
 </div>
</article>""")

counts = {s: sum(1 for m in MOVES if s in m["scenes"]) for s in SCENES}
chips = "".join(f'<button data-s="{e(s)}">{e(s)} {counts[s]}</button>' for s in SCENES)
ek = sum(len(m["files"]) for m in MOVES if m["src"] == "ek")
ekm = sum(1 for m in MOVES if m["src"] == "ek")
yoga = sum(len(m["files"]) for m in MOVES if m["src"] == "yoga")

shots_total = sum(n["shots"] for n in NEEDED)
needed_rows = "".join(
    f'<tr><td><b>{e(n["zh"])}</b><br><code>{e(n["id"])}</code></td>'
    f'<td>{e(n["scene"])}</td><td>{e(n["draw"])}</td>'
    f'<td>{e(n["view"])}</td><td>{n["shots"]}</td>'
    f'<td><code>gen-{e(n["id"])}-a</code>{"<br><code>gen-" + e(n["id"]) + "-b</code>" if n["shots"] > 1 else ""}</td></tr>'
    for n in NEEDED
)
spec_rows = "".join(f"<li><b>{e(k)}</b>：{e(v)}</li>" for k, v in SPEC.items())

HTML = f"""<!doctype html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Vana 动作库 · 待评审清单</title>
<style>
:root {{
  --bg:#f6f6f7; --card:#fff; --fg:#1c1c1e; --dim:#6c6c70; --line:#e3e3e6;
  --accent:#2f6f4f; --warn:#8a4b2a;
}}
@media (prefers-color-scheme:dark) {{
  :root {{ --bg:#111113; --card:#1c1c1f; --fg:#f2f2f4; --dim:#98989d; --line:#2c2c30;
           --accent:#7fc9a2; --warn:#e0a075; }}
}}
* {{ box-sizing:border-box; }}
body {{ margin:0; background:var(--bg); color:var(--fg);
  font:16px/1.65 -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif; }}
header {{ max-width:1200px; margin:0 auto; padding:48px 20px 8px; }}
h1 {{ font-size:30px; margin:0 0 6px; letter-spacing:-.02em; }}
.lede {{ color:var(--dim); max-width:62ch; margin:0 0 18px; }}
.note {{ background:var(--card); border:1px solid var(--line); border-radius:12px;
  padding:14px 16px; max-width:78ch; margin:0 0 18px; font-size:14px; color:var(--dim); }}
.note b {{ color:var(--fg); }}
.note ul {{ margin:8px 0 0; padding-left:18px; }}
.filters {{ display:flex; flex-wrap:wrap; gap:8px; padding:6px 0 0; }}
.filters button {{ font:inherit; font-size:14px; padding:5px 13px; border-radius:999px;
  border:1px solid var(--line); background:var(--card); color:var(--fg); cursor:pointer; }}
.filters button.on {{ background:var(--fg); color:var(--bg); border-color:var(--fg); }}
main {{ max-width:1200px; margin:0 auto; padding:20px; display:grid; gap:18px;
  grid-template-columns:repeat(auto-fill,minmax(320px,1fr)); }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:16px;
  overflow:hidden; display:flex; flex-direction:column; }}
.fig {{ position:relative; height:190px; background:#fff; display:grid; place-items:center; }}
.fig img {{ max-height:170px; max-width:88%; }}
.fig.two img {{ position:absolute; animation:sw 2.6s steps(1,end) infinite; }}
.fig.two img.b {{ animation-delay:1.3s; }}
@keyframes sw {{ 0%,50% {{opacity:1}} 50.01%,100% {{opacity:0}} }}
@media (prefers-reduced-motion:reduce) {{
  .fig.two img {{ animation:none; position:static; max-width:46%; }}
  .fig.two {{ display:flex; gap:6px; }}
}}
.body {{ padding:14px 16px 16px; }}
h3 {{ margin:0 0 8px; font-size:18px; }}
h3 .en {{ display:block; font-size:12px; font-weight:400; color:var(--dim); letter-spacing:.01em; }}
.tags {{ display:flex; flex-wrap:wrap; gap:5px; margin-bottom:10px; }}
.tag {{ font-size:12px; padding:2px 9px; border-radius:999px; background:var(--bg);
  border:1px solid var(--line); color:var(--dim); }}
.meta {{ display:grid; grid-template-columns:auto 1fr; gap:2px 10px; margin:0 0 10px;
  font-size:13px; color:var(--dim); }}
.meta dt {{ color:var(--dim); opacity:.75; }}
.meta dd {{ margin:0; color:var(--fg); }}
.steps {{ margin:0 0 10px; padding-left:20px; font-size:14.5px; }}
.steps li {{ margin:3px 0; }}
.cue, .avoid {{ margin:0 0 6px; font-size:13.5px; line-height:1.55; }}
.cue b, .avoid b {{ display:block; font-size:12px; letter-spacing:.04em; }}
.cue {{ color:var(--fg); }} .cue b {{ color:var(--accent); }}
.avoid {{ color:var(--dim); }} .avoid b {{ color:var(--warn); }}
.src {{ margin:10px 0 0; font-size:11.5px; color:var(--dim); opacity:.8; }}
.todo {{ max-width:1200px; margin:26px auto 0; padding:0 20px; }}
.todo h2 {{ font-size:22px; margin:0 0 8px; letter-spacing:-.01em; }}
.todo > p {{ color:var(--dim); max-width:78ch; margin:0 0 16px; font-size:14.5px; }}
.note.warn {{ border-color:var(--warn); }}
.tablewrap {{ overflow-x:auto; border:1px solid var(--line); border-radius:12px; background:var(--card); }}
table {{ border-collapse:collapse; width:100%; min-width:820px; font-size:13.5px; }}
th, td {{ text-align:left; padding:9px 12px; border-bottom:1px solid var(--line); vertical-align:top; }}
th {{ font-size:12px; color:var(--dim); font-weight:600; letter-spacing:.03em; }}
tbody tr:last-child td {{ border-bottom:0; }}
code {{ font-size:11.5px; color:var(--dim); }}
footer {{ max-width:1200px; margin:0 auto; padding:10px 20px 60px; font-size:13px; color:var(--dim); }}
footer code {{ font-size:12px; }}
</style>
</head>
<body>
<header>
  <h1>Vana 动作库 · 待评审清单</h1>
  <p class="lede">issue #7 的 T1/T2 产物:{len(MOVES)} 个动作,每条都有中文步骤、要领和禁忌。
  这一页只用来评审,不是 app 里的界面,app 里不会有它的入口。</p>
  <div class="note">
    <b>三条硬约束(每条都照着写的)</b>
    <ul>
      <li><b>不给次数、组数、保持秒数</b>——强度按感觉走,同「剂量一律不给建议」那条线。</li>
      <li><b>没有图的动作不进库</b>,它对模型是零增益。</li>
      <li><b>每条都要有「什么情况别做」</b>,写在卡片最后一行。</li>
      <li><b>步骤写给没练过的人看</b>,不用「骨盆后倾」这种词。</li>
    </ul>
  </div>
  <div class="note">
    <b>图片来源与授权(已查清,没有阻塞项)</b>
    <ul>
      <li><b>everkinetic/data</b>({ek} 张,{ekm} 个动作 × 两态)— CC BY-SA 4.0。署名 + 同样授权,
          「关于」页列出处和作者即可。两态就是卡片上交叉淡入的那两帧。</li>
      <li><b>dDara「Yoga poses」@ Flaticon</b>({yoga} 张)— 经 alexcumplido/yoga-api 找到的同一套图
          (那个包 48 个图标,yoga-api 48 个体式,对得上)。<b>我们自己去 Flaticon 持证下载</b>,
          不走 yoga-api 的转授:免费档署名作者,订阅档免署名。唯一限制是不能拿它做 AI 生成。</li>
      <li>Gym visual(exercises-dataset 里的 GIF)、RepDB 一张都没用:前者要单独买且只有 180×180,
          后者禁止随仓库再分发,拉伸也全是要弹力带的。</li>
      <li><b>asanakit 火柴人渲染试过了,砍掉</b>:折叠类姿势糊成一团、正反分不出来。见 issue #7 的评论。</li>
    </ul>
  </div>
  <div class="note">
    <b>还差什么</b>
    <ul>
      <li><b>库里只放有图的动作</b>——一条只有文字的卡片,正是模型不用这个库也能写出来的东西。
          「扶墙小腿伸展」因此没有收进来。</li>
      <li>两套图<b>风格不一致</b>(彩色人物 vs 单色解剖线稿),最终要统一成一套。</li>
      <li>覆盖缺口:颈肩只有 5 条、平衡只有 1 条;手腕前臂、坐姿椅子操、有氧心肺三类完全没有。
          <b>这一页最下面有一份出图清单</b>,{len(NEEDED)} 个动作、{shots_total} 张图,照着生成就能补齐。</li>
    </ul>
  </div>
  <div class="filters" id="f"><button data-s="" class="on">全部 {len(MOVES)}</button>{chips}</div>
</header>
<main id="grid">
{chr(10).join(cards)}
</main>
<section class="todo">
  <h2>待补动作 · 出图清单</h2>
  <p>下面这 {len(NEEDED)} 个动作<b>文字已经写好了，缺的只是图</b>——而没有图的动作不进库，
  所以它们现在一条都不在 app 里。共需 <b>{shots_total} 张</b>。补齐之后，颈肩、平衡两类不再单薄，
  手腕前臂、坐姿椅子操、有氧心肺三类从零到有。</p>
  <div class="note warn">
    <b>两条硬约束</b>
    <ul>
      <li><b>不要拿 dDara 那套图当参考图或垫图。</b>Flaticon 条款明确禁止把它们的素材用于生成式 AI
          （风格迁移、图生图、微调都算）。要接近那个观感只能凭文字描述独立生成。</li>
      <li>生成完先当草稿看一眼<b>姿势对不对</b>。画错关节角度的图比没有图更糟——用户会照着做。</li>
    </ul>
  </div>
  <div class="note">
    <b>出图规格</b>
    <ul>{spec_rows}</ul>
    <p style="margin:10px 0 0">做好之后丢进 <code>tools/gen_svg/</code>，在 <code>moves.py</code> 里
    补上这条动作的步骤/要领/禁忌，再跑一次 <code>build.py</code> 就进库了。</p>
  </div>
  <div class="tablewrap">
  <table>
    <thead><tr><th>动作</th><th>场景</th><th>画什么</th><th>视角</th><th>张数</th><th>文件名</th></tr></thead>
    <tbody>{needed_rows}</tbody>
  </table>
  </div>
</section>

<footer>
  数据文件:<code>Docs/Exercises/exercises.json</code>,素材:<code>Docs/Exercises/assets/</code>。
  两态的图在这里是自动交叉淡入的,那正是 issue #7 里提的卡片形态。
</footer>
<script>
const grid = document.getElementById('grid');
document.getElementById('f').addEventListener('click', ev => {{
  const b = ev.target.closest('button'); if (!b) return;
  document.querySelectorAll('#f button').forEach(x => x.classList.toggle('on', x === b));
  const s = b.dataset.s;
  grid.querySelectorAll('.card').forEach(c => {{
    c.style.display = (!s || c.dataset.scenes.split(' ').includes(s)) ? '' : 'none';
  }});
}});
</script>
</body>
</html>
"""

with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as f:
    f.write(HTML)

print("moves:", len(MOVES), "assets:", len(os.listdir(ASSETS)))
