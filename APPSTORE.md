# 上架清单

app 里的合规部分已经做完（见 CLAUDE.md「架构:合规」）。这份文档是**剩下那半边**：App Store
Connect 里要填的东西。填错的代价和代码里写错一样——审核看到的是这两边**合起来**的样子，对不上
就是一次被拒。

下面「发一个 TestFlight build」是把 build 送上去的流程，其余各节是 ASC 里要填的内容。
**内部测试用不到审核那几节**（备注、年龄分级、隐私标签），但发给别人之前每一节都要填完。

## 发一个 TestFlight build

### 0. 本机先过一遍

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

不过就别往下走——见下面「提交前在本机确认」。

### 1. 团队 ID 要对上

`project.yml` 里那行是 `DEVELOPMENT_TEAM: NGM7GX8DGB`。Xcode > Settings > Accounts 里登录
zjywill@gmail.com，确认这个团队在列表里，而且你的角色是 Account Holder / Admin / App
Manager——**Developer 角色建不了 app 记录**，而它报的错（`DistributionAppRecordProviderError`）
看不出是权限问题。

Team ID 在 developer.apple.com > Membership 那一页；ASC 里没有这一项（「用户和访问 > 集成」
里那个是 Issuer ID，不是一回事）。本机也读得出来：

```bash
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -p - | grep -E 'TeamName|application-identifier' | head -2; echo ---
done
```

**必须是已付费的 Apple Developer Program 团队。** 免费的个人团队能真机调试，但传不了
TestFlight，而它在 Xcode 里长得和付费团队一模一样（名字后面写着 Personal Team）。

**换团队之前先想清楚 bundle id。** 归档时 Xcode 会顺手把 bundle id 注册成当前团队名下的
App ID，而 **bundle id 在 Apple 那边全局唯一**：一旦 ASC 里为它建了记录，那个 App ID 就删不掉
（`appears to be in use by the App Store`），别的团队再也注册不了同一串，而已删除 app 的
bundle id Apple 又明写着不能重用。2026-08-12 就是这么把 `com.pinapia.vana` 丢在
Ardent Core Limited 名下的，现在这串 `.ios` 后缀是那次踩出来的。**先定团队，再归档。**

### 2. ASC 里建 app 记录

上传时 ASC 要先有一条对得上的记录，否则 Distribute 那步报
`DistributionAppRecordProviderError`（Xcode 找不到对得上的记录，就是这一句没头没尾的话）。

1. developer.apple.com > Identifiers：确认 `com.pinapia.vana.ios` 在 **NGM7GX8DGB** 名下。
   归档过一次的话 Xcode 已经自动注册好了，**勾上 HealthKit**（entitlement 里那条
   `health-records` 是它的子项）。
2. appstoreconnect.com > Apps > 新建：平台 iOS、主要语言简体中文、bundle id 选上面那个、
   SKU 随便一个唯一串。
3. 名称填 **Vana**，和主屏显示的名字一致。见下面「名称这一栏」。
4. 新账号第一次用的话，先看 ASC > 业务里有没有待签的协议。没签完同样是那个错。

#### 名称这一栏

App Store 名称是 **Vana**，`INFOPLIST_KEY_CFBundleDisplayName` 也是 **Vana**。现在两边一致，
但**它们本来就不必一致**——记住这一条，因为下次重名时它是最省事的出路。

App Store 名称**全球唯一**，主屏那个名字不要求唯一。2026-08-12 第一次建记录时报了
`The App Name you entered is already being used`——占着「Vana」的**正是自己**：更早在
Ardent Core Limited 名下建的那条记录（就是把 bundle id `com.pinapia.vana` 卡死的同一条）
用了这个名字。到那条记录的「App 信息」里改个名（从没提交过的 app 名称随便改），
「Vana」就放出来了。

所以这两件事的严重程度差很远：**名字是拿得回来的，bundle id 不是。**
`com.pinapia.vana` 永久留在老团队那边，而「Vana」这个名字收回来了。

再往下的两条：

- **名称和 bundle id 不是一类东西**：前者上架前随便改，上架后跟着新版本提交也能改；后者首次
  上传之后永久锁死。所以别为了名称这一栏拖住 build——真被别人占了，先加个后缀把 build 传上去。
- 改名称时只有一条硬约束：**不能有医疗功效的暗示**（「诊断」「筛查」「检测」都不行），而且要
  和 app 实际做的事对得上，否则是 Guideline 2.3。副标题和关键词同理。

### 3. 归档

第一次走 Xcode GUI 最省事（Product > Archive）：自动签名会自己去申请 Apple Distribution 证书
和 profile，本机现在**只有开发证书**，一张分发证书都没有。

命令行等价（`-allowProvisioningUpdates` 是让它去申请那张证书，少了会直接失败）：

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Vana.xcarchive \
  -allowProvisioningUpdates archive
```

### 4. 上传

Xcode > Window > Organizer > 选那个 archive > Distribute App > **TestFlight Internal Testing
Only**（只自己测就够了；要发外部测试或上架就选 App Store Connect）。

出口合规那一问不会再弹——`ITSAppUsesNonExemptEncryption = false` 已经在 Info.plist 里。

### 5. 装到手机上

ASC > TestFlight > 内部测试：把自己（zjywill@gmail.com，Account Holder）加进一个内部测试组。
**内部测试不走 Beta App Review**，build 处理完（几分钟到半小时）就能装。手机上装 TestFlight
app、用同一个 Apple ID 登录。

**要在真机上测。** 模拟器里没有 Apple 健康数据，这个 app 的主线在模拟器上跑不起来。

### 6. 下一次上传

`CURRENT_PROJECT_VERSION`（`project.yml`）**每次 +1**，改完 `xcodegen`。同一个
`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` 的 build，ASC 直接拒收。
`MARKETING_VERSION` 只在对外版本真的变了的时候动。

TestFlight 的 build **90 天后过期**，到期就得重传一个。

## 公开测试（外部测试 + 公开链接）

内部测试是给自己的：**不过审、几分钟就能装、上限 100 人**。给外人用要换一条路——外部测试组
加公开链接，任何人点开链接就能装，**上限 10000 人，不用收 UDID**。

代价是**要过 Beta App Review**：第一个 build 约 1–2 天，之后的 build 一般自动放行，除非改动
很大。所以「内部测试用不到的那几节」（下面的年龄分级、隐私营养标签、审核备注）到这一步全部
到期，一节都跳不过去。

### 步骤

1. ASC > TestFlight > **外部测试** > 新建群组
2. 把 build 分配给这个组
3. 组设置里**启用公开链接**，设人数上限
4. 填「测试信息」，提交审核

### 提交前必须填完的

- **审核备注**（见下面那一节）——**这一条最要紧**。必须给一把能用的 API key，没有它审核员打开
  只看到「还没配置云端模型」，核心功能一步都跑不了，这是 2.1 拒绝里最常见的一种。
- **隐私政策 URL**——先把 `Vana/Legal/PrivacyPolicy.html` 挂到静态站点（GitHub Pages 最省事）。
  必须和 app 包里那份**逐字相同**，审核核对的正是这个。
- **年龄分级问卷**、**隐私营养标签**——各见下面那一节。
- Beta App Description、反馈邮箱、联系人信息。

### 一件先想清楚的事

**这个 app 要用户自己填 API key 才能回答问题。** 公开链接发出去，多数人装上、打开、看到
「还没配置云端模型」，然后就走了——公开测试真正测到的是那批本来就有 key 的人。想要普通用户的
反馈，得先想清楚首次进入那一屏怎么办，否则收回来的不是产品反馈，是流失。

build **90 天过期**，公开链接上的人到期就装不了，得传新的。

## 提交前在本机确认

```bash
xcodegen && xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`VanaTests/ComplianceTests` 盯着下面这几件里能被自动检查的部分：权限用途字符串没有再许
「数据不离开设备」、版本号两项都在、出口合规键在、隐私说明打进了包并且和代码里的备份行为对得上、
急症规则排在系统提示第一条。**这一套过不了就别提交**，它挡住的每一条都是审核会看到的。

Release 产物再手工看一眼（写权限那句 Debug 和 Release 是两份不同的话，见下）：

```bash
plutil -p "$(xcodebuild -project Vana.xcodeproj -scheme Vana -configuration Release -destination 'generic/platform=iOS' -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')/Info.plist"
```

要看到：`CFBundleShortVersionString`、`CFBundleVersion`、`ITSAppUsesNonExemptEncryption = false`、
三条健康/位置/相机用途字符串，以及 **`NSHealthUpdateUsageDescription` 存在、而且是「只读、
不写」那一句**（不是 Debug 里「写入模拟健康数据」那句）。

这一项**少了就传不上去**：上传时的静态检查只看二进制里有没有引用
`requestAuthorization(toShare:read:)`，不管你传的是不是空集合，少了就报
`Missing purpose string in Info.plist`。HealthKit 没有只读的授权 API，所以躲不掉——
别照着「声明一个从不申请的权限是白送审核一个问号」把它删回 Debug-only，那条在这里让位。

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
