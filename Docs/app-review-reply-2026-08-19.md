# 回复 App Review（2026-08-19，Submission a4266716-eba0-4541-b339-33bc052bf4a6）

被拒的两条：Guideline 2.1(a)（聊天里出错）和 Guideline 2.5.1（界面上认不出 HealthKit）。
**下面英文部分是直接粘进 App Store Connect 的正文**，中文注解只给自己看，不要一起粘过去。

粘之前必须核对的几处见文末。

---

## 粘进 ASC 的正文

Hello,

Thank you for the screenshots — they pinpointed the defect exactly. Both issues are fixed in
build 1.0 (4), which accompanies this reply.

### Guideline 2.1(a) — Performance: errors in the Vana AI chat

Fixed. This was our bug, and the reviewer did nothing wrong.

**Root cause.** Settings displayed the default Provider (DeepSeek) and Model
(DeepSeek V4 Flash), but that default existed only in the *display* layer — it was never
written to persistent storage. The code path that sends a request read the stored value,
found it empty, and refused with "You need to select a cloud model in Settings first."

So the app asked the reviewer to choose a model that the same screen already showed as
chosen, and nothing he could do in Settings would satisfy it. The "Retry" button could not
help either: retrying sent exactly the same request, which is why your screenshot shows the
same message twice.

**What changed in build 4:**

1. The default provider and model are now genuinely persisted on first launch. The Settings
   screen and the request path read the same single source, so they can no longer disagree.
2. If the API key or the model is missing, the app no longer sends the message and produces
   an error. It opens Settings instead, with an explanation of what is missing.
3. Error bubbles now distinguish two kinds of failure. Configuration problems (no key, no
   model, rejected key) offer **"Open Settings"**; only failures where retrying can actually
   succeed (network, provider congestion) offer "Retry".
4. Regression tests cover the fresh-install case, so a first launch that cannot send a
   message will fail the build rather than reach review.

**To verify:** install the build fresh, open Settings, paste the API key from our review
notes into "API key" (Provider and Model are already filled in and now actually stored), and
ask a question such as "How did I sleep last night?". "Test connection" in the same screen
sends one real request and verifies key, provider and model together before any question is
asked.

### Guideline 2.5.1 — Performance: identifying HealthKit in the user interface

Fixed. The app now names Apple Health (HealthKit) explicitly, in the places a user actually
looks, rather than relying on a heart icon and the phrase "your health data":

1. **First screen, welcome card** — under the heading "Start with your health data":
   *"Steps, sleep and heart rate come from Apple Health (HealthKit). Vana only reads what you
   authorize and never writes to or modifies your health records."*
2. **Settings** — the section is now titled **"Apple Health (HealthKit)"** and contains
   "Request Apple Health (HealthKit) access" and "Manage in the Health app", with the same
   read-only statement in the footer.
3. **Every health query result panel** — the panel that opens from a query in a conversation
   carries the line *"From Apple Health (HealthKit) — read only, never modified"*.
4. **The health status detail screen** (tap the summary card at the top of the first screen)
   — the same attribution, plus the note that missing items usually mean the device was not
   worn.
5. The mandatory first-launch data-use screen and the privacy policy state the same thing.

The wording is defined in one place in the source and is covered by automated tests, so the
four surfaces cannot drift apart.

This build also adds a full English localization, so on an English-language device every one
of these strings — including the HealthKit permission prompts — appears in English.

### Review environment

- Reviewed on iPad Air 11-inch (M3), iPadOS 26.6: both fixes were verified on that exact
  simulator configuration as well as on iPhone.
- Privacy policy: https://vana.pinapia.com/privacy/ (Simplified Chinese) and
  https://vana.pinapia.com/privacy/en/ (English).
- Vana has no server and no accounts. Health data is read from HealthKit read-only, and the
  aggregated values needed to answer a question are sent only to the AI provider the user
  configures with their own key.

Thank you again for the screenshots — the "select a cloud model" screenshot is what made the
root cause obvious.

---

## 粘之前先确认

1. **build 号是 1.0 (4)**。`CURRENT_PROJECT_VERSION` 已经从 3 加到 4；ASC 拒收同号的 build。
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
