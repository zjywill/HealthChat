#!/usr/bin/env python3
"""把评审页的素材同步进 app:SVG → asset catalog,exercises.json → app 包。

先跑 build.py(它生成 assets/ 和 exercises.json),再跑这个。

SVG 直接进 asset catalog(Xcode 12 起支持),`preserves-vector-representation` 打开——
矢量跟着辅助功能字号缩放不糊,这正是当初不选 512px PNG 的理由。
"""
import json, os, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.dirname(HERE)                 # Docs/Exercises
ROOT = os.path.dirname(os.path.dirname(DOCS))  # 仓库根
APP = os.path.join(ROOT, "HealthChat", "Exercises")
CATALOG = os.path.join(APP, "Exercises.xcassets")
SRC = os.path.join(DOCS, "assets")

shutil.rmtree(CATALOG, ignore_errors=True)
os.makedirs(CATALOG)
json.dump({"info": {"author": "xcode", "version": 1}},
          open(os.path.join(CATALOG, "Contents.json"), "w"), indent=2)

count = 0
for filename in sorted(os.listdir(SRC)):
    if not filename.endswith(".svg"):
        continue
    # 资源名就是去掉扩展名的文件名,和 exercises.json 里的 files 对得上
    # (`ExerciseMove.imageNames` 只做这一件事)。
    imageset = os.path.join(CATALOG, filename[:-4] + ".imageset")
    os.makedirs(imageset)
    shutil.copyfile(os.path.join(SRC, filename), os.path.join(imageset, filename))
    json.dump({
        "images": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True},
    }, open(os.path.join(imageset, "Contents.json"), "w"), indent=2)
    count += 1

shutil.copyfile(os.path.join(DOCS, "exercises.json"), os.path.join(APP, "exercises.json"))
print(f"imagesets: {count} → {CATALOG}")
print("别忘了 xcodegen(增删文件之后工程要重新生成)")
