# 上架清单

app 里的合规部分已经做完（见 CLAUDE.md「架构:合规」）。这份文档是**剩下那半边**：App Store
Connect 里要填的东西。填错的代价和代码里写错一样——审核看到的是这两边**合起来**的样子，对不上
就是一次被拒。

## 提交前在本机确认

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`VanaTests/ComplianceTests` 盯着下面这几件里能被自动检查的部分：权限用途字符串没有再许
「数据不离开设备」、版本号两项都在、出口合规键在、隐私说明打进了包并且和代码里的备份行为对得上、
急症规则排在系统提示第一条。**这一套过不了就别提交**，它挡住的每一条都是审核会看到的。

Release 产物再手工看一眼（Debug 里多一个写权限的用途字符串，那是 `DebugSeeder` 用的）：

```bash
plutil -p "$(xcodebuild -project Vana.xcodeproj -scheme Vana -configuration Release -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')/Info.plist"
```

要看到：`CFBundleShortVersionString`、`CFBundleVersion`、`ITSAppUsesNonExemptEncryption = false`、
三条健康/位置/相机用途字符串，以及**没有** `NSHealthUpdateUsageDescription`。

## 隐私政策 URL

内容是 [`Vana/Legal/PrivacyPolicy.html`](Vana/Legal/PrivacyPolicy.html)，同一个文件既
打进 app 包（设置 > 关于 > 隐私说明），也直接发布。挂到任意静态站点即可（GitHub Pages 最省事），
把地址填进 App Store Connect 的 Privacy Policy URL。

**两处必须是同一份内容。** 改了这个文件要重新发布一次，否则 app 里和网上说的话不一样，而审核
核对的正是这个。

## 年龄分级

问卷里勾 **「医疗/治疗信息」（Medical/Treatment Information）—— 频繁/强烈**。这个 app 的主线
就是解读健康数据和化验单。别为了拿低分级往轻里填：分级问卷答得和 app 实际做的事不符，是
Guideline 2.3（准确的元数据）。

其余项全是「无」：不含暴力、性、赌博、酒精药物（用药表是用户自己的用药记录，不是药物内容）。

## 隐私营养标签（App Privacy）

判据是**「离开设备了吗」**。Vana 自己没有服务器，但数据会发给用户配置的模型服务——那仍然算
「收集」，因为它离开了设备。不能因为「不是我们收的」就全填 Not Collected。

| 类别 | 填什么 | 说明 |
| --- | --- | --- |
| Health & Fitness | Data Used to Link to You? **否**；Used for Tracking? **否**；Purpose: App Functionality | 聚合数值随问题发给用户自选的模型服务 |
| Sensitive Info | 同上 | 化验单、体检记录识别出来的文字 |
| User Content（Photos, Other User Content） | 同上 | **照片本身不发**，只有本机识别出来的文字；仍按 User Content 填 |
| Coarse Location | 同上 | 只到城市，且只在用户授权后 |
| Contact Info / Identifiers / Usage Data / Diagnostics | **Not Collected** | 没有账号、没有埋点、没有崩溃上报 |

三项都要勾 **Not Linked to You**（没有账号，服务端没有可以关联的身份）和 **Not Used for
Tracking**（不做广告、不和第三方数据做匹配）。

## 审核备注（App Review Notes）

**必须给一把能用的测试 API key**，否则审核员打开 app 只看到「还没配置云端模型」，核心功能一步都
跑不了——这是 2.1 拒绝里最常见的一种。备注里写清楚：

```
Vana 需要用户自己的云端模型 API key 才能回答问题（app 自身没有服务器，也不代收费用）。
测试账号：设置 > 云端模型 > API key 填入 <这里放一把额度足够的 key>，Provider 选 Anthropic，
模型选 Claude Sonnet 5。

健康数据：模拟器里没有 Apple 健康数据。请在真机上测试，或在「健康」App 里手动添加几条
步数/睡眠记录后再提问。app 对 HealthKit 只读。

首次启动会先显示一屏「在开始之前」，说明哪些数据会发给用户配置的模型服务。
免责声明与隐私说明在：设置 > 关于 Vana。
```

## 健康档案（Clinical Health Records）权限

entitlement 里申请了 `com.apple.developer.healthkit.access: health-records`。这一项审核更严，备注里
要说明用途和边界：

```
用于读取用户已在「健康」App 中连接的化验结果与体征（不读取诊断和用药记录），
以便在对话中解释这些数值。数据只在用户提问时读取，不用于广告或数据挖掘，
不出售给任何第三方，也不保存到 iCloud（相关文件已排除出设备备份）。
```

## 出口合规

`ITSAppUsesNonExemptEncryption = false` 已经写进 Info.plist，上传时不会再被问。只用 HTTPS 和系统
自带的加密（Keychain、文件保护），属于豁免范围。**如果以后自己实现了加密算法，这一项要重填。**

## 容易忘的几条

- **截图和描述里不能宣称医疗功效**。「帮你看懂自己的健康数据」可以，「诊断」「治疗」「筛查」不行。
- app 名称、副标题、关键词里同样不要出现疾病名当卖点。
- 换机之后数据不跟着走（健康数据不进备份，见隐私说明）。这一条最好在商店描述里也写一句，
  否则用户换手机之后会当成 bug 来投诉。
- 每次改动权限用途字符串、隐私说明、年龄分级问卷任意一处，都要回头看另外两处还对不对。
