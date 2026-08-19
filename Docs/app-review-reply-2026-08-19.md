# 回复 App Review（2026-08-19，Submission a4266716-eba0-4541-b339-33bc052bf4a6）

被拒的两条：Guideline 2.1(a)（聊天里出错）和 Guideline 2.5.1（界面上认不出 HealthKit）。
**下面英文部分是直接粘进 App Store Connect 的正文**，中文注解只给自己看，不要一起粘过去。

粘之前必须核对的几处见文末。

---

## 粘进 ASC 的正文

Hello,

Both issues are fixed in build 1.0 (5).

**2.1(a) — errors in the chat.** Settings showed the default Provider (DeepSeek) and Model
(DeepSeek V4 Flash), but that default only ever existed on screen — it was never saved, so
the code that sends a request read an empty model and refused with "select a cloud model in
Settings first". The app was asking for a choice the same screen already showed as made, and
Retry sent the identical request. This build saves the defaults on first launch, so the screen
and the request path read the same value; when a key or model really is missing it opens
Settings instead of failing; and configuration errors now offer "Open Settings" rather than
"Retry". Regression tests cover the fresh-install case.

**2.5.1 — identifying HealthKit in the interface.** Apple Health (HealthKit) is now named in
four places: the welcome card on the first screen ("Steps, sleep and heart rate come from
Apple Health (HealthKit). Vana only reads what you authorize and never writes to or modifies
your health records."), the Settings section titled "Apple Health (HealthKit)", the footer of
the health status detail screen, and the header of every query result panel in a
conversation. This build also adds an English localization, so those strings — and the
HealthKit permission prompts — appear in English on an English device.

**Setup (the test key is in App Review Information > Notes):**

1. Settings (gear, top right) > "Cloud model" > "API key" > paste the key.
2. The rows below should already read Provider: DeepSeek, Model: DeepSeek V4 Flash. Our key
   works only with DeepSeek.
3. Tap "Test connection" — it validates key, provider and model together. Expect
   "Connected. You're ready to ask."
4. Ask a question, e.g. "How did I sleep last night?". A simulator has no Apple Health data,
   so add a few samples in the Health app first, or test on a device.

Privacy policy: https://vana.pinapia.com/privacy/ (Simplified Chinese) and
https://vana.pinapia.com/privacy/en/ (English).

Thank you for the screenshots — the "select a cloud model" one made the root cause obvious.

---

## 粘之前先确认

1. **build 号是 1.0 (5)**。4 传上去之后又修了「回到底部」那颗按钮，所以再加一位；ASC 拒收同号的 build。
2. **审核备注里那把 DeepSeek key 还有额度**。上一轮就是这条路上出的事：审核员粘完 key 之后
   一步都跑不动。传之前自己用「测试连接」验一次。
3. **录屏**。2.5.1 那条 Apple 明写了"如果已经标了，回信附一段真机录屏"。上面正文里**没有**
   声称附了录屏——真录了再加一句，没录就别提。录的话按这个顺序走一遍：首屏欢迎卡那句
   →设置页「Apple Health (HealthKit)」那一节→随便问一句、点开结果面板顶上那行字。
4. **ASC 里加英文本地化**。app 现在有英文了，而商店页面还只有简体中文——英文设备上装下来
   界面是英文、商店描述是中文。至少补：App 名称/副标题、描述、关键词、截图，以及英文那一份
   隐私政策 URL（`https://vana.pinapia.com/privacy/en/`）。
5. **本机跑一遍**：`xcodegen && xcodebuild ... test`（两套都要过），再归档。

## 这次改了什么（自己看的）

- `EngineSettings.seedDefaultsIfNeeded` / `selection`：默认值真的落盘，显示和发请求同一个来源
- `ChatViewModel.currentSetupGuidance` / `recovery(for:)`：缺模型时挡在发送之前；报错气泡分
  「去设置」和「重试」两种
- `HealthKitAttribution`：一处定义，首屏 / 设置页 / 结果面板 / 状况详情页四处同一句话
- `VanaTests/CloudSetupTests` + `ComplianceTests`：全新安装发得出消息、四句话都报得出
  「健康」App 和 HealthKit
- 英文本地化：界面、权限用途字符串、首次告知那一屏、隐私说明各一份英文
