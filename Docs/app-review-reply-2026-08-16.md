# 回复 App Review（Submission a4266716-eba0-4541-b339-33bc052bf4a6）

2026-08-16 那次拒绝的五条，逐条答复。**下面英文部分是直接粘进 App Store Connect 的正文**，
中文注解只给自己看，不要一起粘过去。

提交前必须核对的两处，见文末「粘之前先确认」。

---

## 粘进 ASC 的正文

Hello,

Thank you for the detailed review. Below is a point-by-point response. Items 1–3 are fixed
in the build accompanying this reply; items 4 and 5 are answers to your questions.

### Guideline 1.5 — Safety: Support URL

Fixed. `https://vana.pinapia.com/support/` is now live and returns HTTP 200.

The domain was pointed at our static host but the host had not been configured to serve that
hostname, so every request returned an HTTP 522 error. That configuration has been corrected.
The page now contains contact information (email, answered within 1–2 business days), setup
instructions, a troubleshooting FAQ, and instructions for deleting all app data.

`https://vana.pinapia.com/privacy/` is also live and returns HTTP 200.

### Guideline 2.1(a) — Performance: 401 error in the chatbot

Fixed, and thank you — this was a real defect and your reproduction steps identified it exactly.

**Root cause.** Vana requires the user to supply their own API key for a third-party AI service
(see item 5 below). When no key had been configured, the send action still issued the network
request. The provider correctly rejected it with HTTP 401, and the app displayed the provider's
raw error text — including the literal string "401" — in the conversation. The only on-screen
hint that setup was required was a small gray footnote at the very bottom of the welcome card,
which was easy to miss.

**Fix**, in the accompanying build:

1. The send action now checks for a configured key before issuing any request. If none is
   present, no request is made, so the 401 can no longer occur. The app navigates directly to
   the settings screen where the key is entered, and the user's typed text is preserved.
2. The setup prompt has been moved from a footnote to a highlighted, tappable banner at the top
   of the first screen.
3. Provider error strings are no longer shown verbatim. Authentication, quota, context-length,
   and transient network failures are each translated into a plain-language message describing
   what the user can do next.

We reproduced your exact steps on an iPad Air 11-inch (M3) running iPadOS 26 and confirmed the
401 no longer appears.

### Guideline 4.2.3(ii) — Design: Minimum Functionality

Fixed.

The additional resource is Apple's on-device speech recognition model, downloaded through
`AssetInventory` in the Speech framework. It is used only by the optional press-and-hold voice
input button, so that dictation runs entirely on device. Previously the app started this
download automatically the first time the user pressed that button, without disclosing the size
or offering a choice.

In the accompanying build, pressing that button now presents a confirmation dialog that states
the download size and offers "Download" and "Not now". Nothing is downloaded unless the user
chooses "Download". The corresponding button in Settings also displays the size on the button
itself. The app remains fully usable if the user declines: the system keyboard's dictation key
and normal typing are unaffected.

### Guideline 2.1 — Information Needed: Clinical Health Records API

**How the app integrates with the API, where information is uploaded, and at what frequency**

Vana reads two clinical record types, read-only: `HKClinicalType(.labResultRecord)` and
`HKClinicalType(.vitalSignRecord)`. It requests no other clinical types — notably not diagnoses,
medications, allergies, or procedures. Vana never writes to HealthKit.

Records are read **only on demand**. When the user asks a question about lab or checkup results,
the assistant invokes an internal tool named `health_records`, which requests Clinical Records
authorization at that moment and performs a single query. There is no read at launch, no
background read, and no scheduled synchronization. If the user never asks such a question, these
records are never accessed.

From each record, Vana extracts only three fields: the display name, the date, and the numeric
value with its unit (parsed from the FHIR `valueQuantity` field). The raw FHIR resource is not
retained and is never transmitted.

**Vana has no server.** We operate no backend of any kind and receive no user data whatsoever.
Nothing is uploaded to us, at any frequency.

Those three extracted fields are included in the prompt sent to the AI provider that the user
configured with their own API key (for example Anthropic, OpenAI, or DeepSeek), solely for the
request that answers that question. That transmission is disclosed in
`NSHealthClinicalHealthRecordsShareUsageDescription`, and again on a mandatory first-launch
screen the user must acknowledge before using the app.

**Which features require this information, how it is enabled, and how it is turned off**

Only the conversational feature uses it, and only for questions about lab or checkup results.
No other feature reads clinical records.

Enabling it requires three separate user actions: connecting a healthcare institution in Apple's
Health app, granting Vana read access to Clinical Records in the system Health permission sheet,
and asking a question on that subject.

It can be turned off at any time in Health › Sharing › Apps › Vana, per data type. Vana then
reports that it cannot read those records; no other behavior changes and no other feature is
affected. Deleting the app removes all locally stored data, as everything lives in the app
sandbox.

**How else the information is used**

It is not used for anything else. Specifically: no advertising, no marketing, no use-based data
mining, no analytics, no model training, and no sharing with any third party other than the AI
provider the user themselves configured. The app contains no analytics or telemetry SDK of any
kind.

**Where the information is stored and who has access**

Only in the app's sandbox on the user's device, inside conversation files under `Documents/`.
These are explicitly excluded from iCloud and from device backups, in accordance with HealthKit
requirements, and are written with file protection enabled.

Access is limited to the user on that device. Vana holds no copy, because Vana has no server.
The only other party that sees these values is the AI provider the user selected, under that
provider's own terms, through the user's own account.

Vana's source code is public at `https://github.com/zjywill/Vana-iOS`, so every statement above
can be verified directly.

### Guideline 3.1.1 — Business: Payments - In-App Purchase

We would like to respectfully clarify the app's business model, as we believe the premise of
this item may not match how Vana works.

**Vana is entirely free and has no paid functionality of any kind.** Specifically:

- The app contains no In-App Purchases, no subscriptions, no paid tier, and no premium features.
  There is no StoreKit code in the project and no In-App Purchase capability in its entitlements.
- We receive no payment from users, through any channel — not through the App Store, and not
  outside it. Vana has never charged anyone anything.
- No feature is gated behind a payment to us or to anyone else. There is no locked content, no
  trial, and no upgrade path, because there is nothing to upgrade to.
- We do not sell, resell, bundle, or earn any commission on API keys, and the app contains no
  link to any purchase flow.

The API key is not a purchase made in or for Vana. It is a **connection credential** for an
account the user already holds directly with a third-party AI service. The relationship is the
same as an email client requiring the user's own email account, or an SSH client requiring the
user's own server: the app is the tool, and the account is the user's own, held with someone
else entirely. Whatever the user pays that provider is a matter between them and that provider,
for their own general-purpose account which they can use with any software they like. None of it
reaches us, and none of it is a payment for anything inside Vana.

We want to be equally direct about what does not work without a key: the conversational feature
cannot run, because there is no model to run it. The rest of the app does work — on-device
health readings and summaries, the lab-report and prescription OCR, the medication and
supplement list, and the health detail views all function normally. But we are not claiming the
conversation works without a credential; it plainly cannot, in the same way an email client
cannot fetch mail without an account.

If, having considered the above, you still consider this arrangement non-compliant, we would be
grateful if you could tell us specifically which functionality is considered "paid functionality
unlocked by a mechanism other than In-App Purchase". We will make whatever change is required —
we would simply like to be certain we are correcting the right thing before we rebuild.

Thank you for your time.

---

## 粘之前先确认

1. **语音模型那个体积数。** 代码会先向系统要真实字节数，问不到才退回 500 MB 的约数。
   在真机上打开设置页看一眼那颗按钮上写的是什么——如果就是「500 MB」，说明系统没给数，
   得实测一遍真实体积再改常量。**跟 Apple 报错体积本身就是 4.2.3 的问题。**

2. **审核备注要补一把可用的测试 key。** Apple 第一封信第 4 条明确要
   "any required login credentials"。审核员读不懂中文界面，401 虽然修好了，但他仍然要
   自己摸索怎么配置。在 App Review Information 的 Notes 里放一把测试 key 加三步英文说明，
   能省掉一整轮往返。这一步和 3.1.1 的申辩不冲突：给审核员一把 key 是为了让他跑通流程，
   不是在卖东西。

## 3.1.1 这条的风险

上面那段申辩事实全部为真、可核查，但**它不保证过**。Apple 在 BYOK 这件事上近年偏紧，
而且我们确实承认了"没 key 就聊不了天"。真被驳回的话，退路只有两条：接自己的后端加 IAP，
或者砍掉云端只留端上模型——两条都推翻现在的产品形态，所以值得先花一轮把话说清楚。

结尾那句「请指出具体是哪个功能」是有意留的：它把球踢回去，要么拿到一个可执行的具体要求，
要么对方发现确实没有可指的东西。
