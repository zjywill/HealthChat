# 回复 App Review（2026-08-22，Submission a4266716-eba0-4541-b339-33bc052bf4a6）

被拒一条：Guideline 2.1(a)，iPad Air 11-inch (M4) / iPadOS 26.6.1 上点「Apple Health」那颗按钮
之后指示器一直转。**下面英文部分是直接粘进 App Store Connect 的正文**，中文注解只给自己看，
不要一起粘过去。

粘之前必须核对的几处见文末。

---

## 粘进 ASC 的正文

Hello,

Fixed in build 1.0 (6). Thank you for the device details — they pointed straight at it.

**What happened.** The button is "Request Apple Health (HealthKit) access" in Settings. It asks
HealthKit for authorization and then waits for the permission sheet's result, and the row shows
"Requesting…" while it waits. If that call never returns, the row has no way back — which is the
behaviour you saw.

One thing separates that request from the one the app makes at first launch, which worked on the
same device: the Settings request also included two clinical types (lab result records and vital
sign records — Health Records). Health Records is not available on every device or in every
region, and we were requesting authorization for those types without first calling
`supportsHealthRecords()`, which HealthKit's documentation requires. We do not have an iPad Air
here to observe the stall directly, so we fixed both the precondition we were violating and the
interface state that made it unrecoverable.

**The fix, in two parts.**

1. We now call `supportsHealthRecords()` before requesting any clinical type, as the HealthKit
   documentation requires. Where Health Records is unavailable, those two types are simply left
   out of the request, and the lab-results feature says so plainly instead of asking the user to
   connect a hospital that this device could never connect to. All other Apple Health data types
   are requested exactly as before.
2. The button itself can no longer display an indefinite loading state. If the permission sheet
   does not respond within 20 seconds, the loading indicator stops and the row explains that
   access can be managed in the Health app instead. While the original system request remains
   unresolved, Vana prevents additional authorization requests from being started.

We verified the fresh-install and Settings authorization flows, confirmed that the row recovers
when the system does not answer, and added regression tests covering the authorization type
selection and the message shown when Health Records is unavailable.

While there, we also fixed the explanatory paragraph directly under that button: half of it was
still displaying in Chinese on an English device.

**Setup (the test key is in App Review Information > Notes):**

1. Settings (gear, top right) > "Cloud model" > "API key" > paste the key.
2. The rows below should already read Provider: DeepSeek, Model: DeepSeek V4 Flash. Our key
   works only with DeepSeek.
3. Tap "Test connection" — it validates key, provider and model together. Expect
   "Connected. You're ready to ask."
4. Ask a question, e.g. "How did I sleep last night?". Apple Health on a new device has no data,
   so add a few samples in the Health app first.

Privacy policy: https://vana.pinapia.com/privacy/ (Simplified Chinese) and
https://vana.pinapia.com/privacy/en/ (English).

---

## 粘之前先确认

1. **build 号**。正文写的是 1.0 (6)，和 `project.yml` 里的 `CURRENT_PROJECT_VERSION` 一致。
   ASC 里要是已经有一个 6，就继续加一位，并同步修改工程和正文；ASC 拒收同号的 build。
2. **审核备注里那把 DeepSeek key 还有额度**。传之前自己用「测试连接」验一次——上上轮就是
   这条路上出的事。
3. **这一条只能靠真机验到一半**。模拟器上 `supportsHealthRecords()` 恒为 false，所以「不支持
   的设备上不问病历」这条路本机走得通；而「支持的设备上照问」那条只有真机能验。看门狗那条
   两边都验过（临时把请求挂住，按钮 20 秒后自己回来）。
4. **本机跑一遍**：`xcodegen && (cd AgentRuntime && swift test)` 和 iPhone 17 上那套
   `xcodebuild test`，再归档。

## 这次改了什么（自己看的）

- `HealthStore.supportsHealthRecords` / `requestedTypes(force:supportsHealthRecords:)`：
  病历那两类先问这台设备有没有，没有就整个不问；判断拆成纯函数，测试喂那个 Bool
- `HealthStore.clinicalRecords`：不支持时抛 `healthRecordsUnavailable`，不去申请也不去查
- `HealthTools.healthRecordsUnavailableReport`：说的是「拍一张」，不是「去连接医院」；不是错误
- `SettingsView.requestHealthAuthorization`：20 秒看门狗，到点把按钮放回去并指向「健康」App；
  **不取消**那次请求，它晚一点回话时说的仍然是对的那句
- `HealthKitAttribution.settingsFooter`：那段脚注原来是 `String` 拼接，编译器抽不到，
  英文设备上后半段一直是中文——审核员看到的正是这一节
- `VanaTests/HealthAuthorizationTests`：四条
