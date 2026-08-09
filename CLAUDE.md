# HealthChat

iOS 26 SwiftUI 聊天 app:agent 通过工具调用读 Apple Health,对话式分析。整体计划见 PLAN.md(里程碑推进,一次一个可见改动)。

用户看到的名字是 **Vana**(`CFBundleDisplayName`、界面文案、图标)。工程名、target、scheme、bundle id 和 Keychain service 仍然叫 HealthChat——换掉它们会让已存的 API key 和已授权的健康数据全部对不上,不值得。

## 构建

`project.yml` 是工程唯一事实来源,增删文件后必须重新生成:

```bash
xcodegen
xcodebuild -project HealthChat.xcodeproj -scheme HealthChat \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

## 测试

两套,都要过:

```bash
(cd AgentRuntime && swift test)   # agent core,秒级,不需要模拟器
xcodebuild -project HealthChat.xcodeproj -scheme HealthChat \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`HealthChatTests` 是 app 侧的 loop 集成测试:脚本化的假模型 + 假能力,但 `ChatViewModel`、
事件归约、预算、压缩、换模型迁移都是线上那一套。改 agent 循环相关的东西先看这里。

## 运行

模拟器安装运行用 iOS Simulator MCP 的 build/launch(bundle id `com.junyizhang.HealthChat`),先 attach 让用户看到面板。

## 架构:通用 agent core

`AgentRuntime` 是本地 SwiftPM 包,**不 import 任何模型 SDK,也不认识 HealthKit**。它只认两个协议:

- `AgentModelClient`——「一个能估 token、能流式跑一轮的模型」。`AIKitModelClient` 是唯一实现。
- `CapabilityRegistry`——「一组 JSON Schema 加一个执行闭包」。`HealthTools.registry` 是唯一实现。

`AgentLoop` 在这两者之上跑工具循环。上下文管理是它最要紧的部分,从轻到重:

0. **单次工具输出的硬上限**(`ContextPolicy.maxToolOutputCharacters`,默认 6000 字符)——
   进上下文之前就截,按行边界截。后面几档都是亡羊补牢:一次调用返回几万字符的话,那一轮
   的原始输出在被压之前必须先原样发出去一次。`metadata` 不截,图表和原始行只给界面看。
1. **整段摘要**(`ModelSummarizer`)——估算跨过 `compactionThreshold`(默认预算的 80%)就叫
   模型把远处那段写成 artifact。**发请求之前**做,不是撞墙之后:撞墙时已经没有从容处理的
   余地了。artifact 通过 `.historyCompacted` 事件交回 app 存盘,下轮直接复用,不重算。
   第二次压缩走**增量更新**:`SummarizationPlan.previousSummary` 带上一版摘要,`spanText`
   只放这之后的新对话。压摘要的摘要会让最早那几轮很快只剩一句客套。
2. **逐轮压缩**(`TranscriptCompactor`)——把某一轮的原始工具输出换成它的摘要形态。总结失败
   时也退回这一档,绝不让用户这一句问不出去。
3. **丢最老的一轮**——前两档都不够时的最后手段。
4. 还塞不下就报 `contextWindowExceeded`,不偷偷发一个超长 prompt 出去。

第 1 档排在第 2 档前面是有意的:机械压缩免费但会铲平工具轨迹,模型摘要花钱但留得住结论。
省那一次调用不值得拿追问要用的数据去换。

**规划的开销是手机上的一等问题**,这段每个工具轮都要跑一遍,而且跑在用户已经在等的时候:

- 不需要压缩时(绝大多数会话)只估一次,和没有这套东西时一样贵。
- 需要压缩时才建 `CostModel` 按条记账,只在被改动的那条上重估。别改回「每压一条就全量重估
  一遍」——那是 O(n²),110 轮的会话实测 717ms,改完 86ms。
- 逐条计价走 `estimateMessageTokens`(不带工具面)。工具 schema 是每次请求算一遍的常量,
  跟着每条消息重新序列化一遍占掉三成耗时。
- 成本模型假设估算可加,这个假设**只用来挑压谁**。报给上层的 `estimatedPromptTokens` 和
  预算判断永远是估算器对整份 prompt 的结果;偏了就退回逐条重估兜底。

`HealthChatTests/ContextBudgetPerformanceTests` 盯着耗时和 `phys_footprint` 峰值,改这块先看它。

## 架构:失败处理

同样分档,越靠外越少见。原则是**能自愈的不要惊动用户,惊动了就要说人话**:

- **工具失败** → 变成一条 `isError` 的结果继续跑。模型自己会换个问法。
- **模型失败** → `ModelFailure` 分类,分两条通道:传输层看 `NSURLErrorDomain` 的错误码
  (`localizedDescription` 是跟着系统语言走的,中文手机上永远匹配不上 "timed out");
  provider 侧看返回的原文(那段不本地化,而且经过 SDK、网关转手之后只剩它)。
  - 拥塞、限流、网络抖动 → 指数退避重试(`RetryPolicy`,默认 3 次)。重跑之前先发一个
    `.textRolledBack` 把已经吐出去的半句撤掉,否则半句会和重试的整句连在一起。撤字和
    `.retryScheduled`(告诉用户在重试)是两个事件:重跑不一定是重试,压缩后重跑也要撤字。
  - 额度、鉴权、模型不存在 → 立刻上报。对着「key 不对」重试三次只是把同一句话说三遍,
    还把真正的原因往后拖了十几秒。
  - 上下文超限 → 不重试(原样再发还是塞不下):强制总结一次 + 把校准比例放大 25%
    (provider 说估小了就是估小了)+ 水位线降到 `thresholdAfterOverflow`,然后重跑这一轮。
    只做一次;再超就报 `contextWindowExceeded`,让用户去开新对话。
- **模型在吐 tool_use 的中途被输出上限截断**(`finishReason == .length` 且有 pendingCalls)
  → 这一批**一个都不执行**,每个都回一条 error 结果让模型重发。JSON 能抢救出来不代表参数
  完整,拿半截日期去查会查出一组看着很正常但是错的数字。
- **工具轮数用光** → 不是错误。照常 `turnCompleted`,finish reason 记 `toolRoundLimitReason`,
  已经查到的东西全部留着。把三次查询结果丢掉去报一个「查询次数过多」对用户是净损失。

压缩本身也发事件(`.compactionStarted` / `.compactionFailed`)。静默降级等于线上出问题时
无从查起。

最近 `preservedRecentTurns`(默认 2)轮在第 1、2 档里受保护:刚查完的数据被压成一句摘要,
用户下一句「那第三天呢」就答不上来了。只有真超预算才动它们。

`ContextCalibration` 按 provider+model 归档本地估算和实际计费的比值,换模型即作废。取最近
几次的**中位数**,离谱的样本直接丢:命中缓存的那一轮 provider 可能只报没走缓存的部分,只信
最近一次的话下一轮就拿这把废尺子去量。

几条不要破坏的边界:

- **换模型本身不是丢历史的理由**。`whenWindowShrinks` 只决定「先压谁」(从大窗口带过来的
  那几轮排前面)和把阈值降到 `thresholdAfterModelSwitch`,压不压由预算说了算。之前那版
  换个模型就把所有工具轨迹铲平,哪怕整段对话只有两轮——白丢了追问要用的数据。

- 会话文件里不能出现 AIKit 类型。transcript 存 `AgentTranscript`,旧格式在 `ChatMessage`
  的 decoder 里翻译一次(有测试盯着)。
- compaction artifact 分两份读者:`visibleSummary` 给用户,`replaySummary` 给模型(多带一段
  工具轨迹)。不要退化成「只回放可见文本」。
- app 写给用户的占位文案("已停止回复")打 `textIsPlaceholder`,runtime 靠这个标记判断要不要
  回放——不要让 runtime 去比对某句中文。

- **assistant 的 `.reasoning` 是数据,不是日志**。DeepSeek 的思考模型规定:带 `tools` 的请求
  必须把每一条中间 assistant 的 `reasoning_content` 原样发回去,少一条就是 400。所以
  transcript 里的 `.reasoning` 不能在存盘、回放、迁移的任何一环被顺手删掉。发不发由 AIKit
  按 `ModelInfo.interleaved.field` / dialect 决定——反过来对着一个没听过这字段的 provider
  发它,同样是 400。

## 架构:记忆(`HealthChat/Memory`)

「关于这位用户」的长期记忆。`MemoryStore`(actor,`Documents/memory.json`)存,
`MemoryExtractor`(后台抽)和 `MemoryTools`(对话里当场记)写,
`MemorySnapshot.instructionBlock` 拼进 system 段,`MemoryView` 给用户改。

**没有索引层,也不要加**。Claude Code 那种「MEMORY.md 索引 + 按需读」是为了几百条记忆装不进
上下文而存在的,代价是漏召回——索引说有、模型没去读。这里的记忆对象只有一个人,全部加起来
几十条、一两千 token,全量进 system 段最简单也最可靠,上限(40 条 / 2000 字)就够了。

三条不要破坏的边界:

- **记忆里不存 HealthKit 查得到的数字**。存「昨晚睡了 6.2 小时」明天就是错的,存「他觉得
  睡够 7 小时才算好」永远对。这条不是靠提示词维持的:`MemoryExtractor.transcript(of:)`
  **只喂用户和助手说过的话,工具输出一条都不给**——它无从记起。别为了「让抽取器看到结论」
  把工具结果加回去。
  这条同时消掉了失效问题:不存易腐的东西就不用做 TTL。唯一带时限的是 `followUp`。
- **快照绑在会话上,会话之内不换**(`ChatViewModel.memory` → `AIKitEngine(memory:)`)。理由
  和「系统提示里的今天只精确到天」一样:system 段中途变化打掉 prompt 缓存,也让模型对用户的
  认知在一条对话里跳变。引擎不许自己去读盘。抽取写在会话结束、快照读在会话开始,正好配套。
- **用户主动写下或说出的(`origin != .extracted`,即 `pinned`)不许被抽取器动**,淘汰时也永远
  跳过。他改成那样就是不认同模型的说法,后台跑一遍又改回去,等于那个设置页是假的。
  `origin` 三态(`manual` 设置页手写 / `asked` 对话里让 Vana 记 / `extracted` 后台抽)是
  存下来的一等字段,界面每条都要说清「这句哪来的」。

写入有两条路,**互补,不是替代**:

- **`remember` 工具**(`MemoryTools`)——用户明说「记住我不能跑步」时当场落,气泡上出现
  「记住了「…」」。只留后台抽取的话,他关掉 app 之前无从知道到底记没记住。
- **会话结束抽取**(`MemoryExtractor`)——多数该记的事用户根本不会明说,而让模型每轮都去
  调一次 `remember` 是让用户多等一个往返。

只留一条都不行,所以两条都在。记忆关掉时 `remember` 连挂都不挂出去
(`CapabilityRegistry.healthChat(allowsMemoryWrites:)`):给一个只会报错的工具,模型得先调一次
才知道不行。**隐私会话走同一个开关**——两条写入路径必须一起堵,只挡抽取的话,模型在对话中途
调一次 `remember` 就把「不保存」变成了假话。工具不挂出去,system 段里那段「该记就调 remember」
也跟着不发:它本来就是照着 registry 里有没有这个工具拼的。

其余几处判断:

- 抽取跑在**会话结束**(切会话 / 退到后台),不是每一轮结束——每问一句多付一次调用,而多数
  健康对话三五轮就完了。门槛在 `MemoryHarvest.shouldHarvest`:隐私会话永不抽(说好不存就是
  不存),一问一答不抽,`memoryHarvestedMessageCount` 之后没有新消息不抽。**删掉的会话也
  不抽**——用户刚把这段对话删了,再从里面记下点什么是反着来的。
- **`followUp` 到期不等于删除**。到期那一刻正是它要派上用场的时候:进早上那条 check-in
  (`CheckInScheduler.content` 里排在所有触发点前面——那是用户自己定下的约定,触发点只是数据
  里冒出来的现象),进 system 段时标上「说好的时间已经到了」。点开通知就把那条删掉,否则
  接下来几天的早上会重复同一句。真正消失要再过 `MemoryStore.followUpGrace`(3 天)。
- 抽取器输出的是**操作**(add / update / delete),不是新的一份记忆全文。只会 append 的话
  三个月后有四十条「关心睡眠」;每次全量重写又会像「摘要的摘要」一样把最早那几条磨平。
  和 `SummarizationPlan.previousSummary` 同一个道理。
- 给模型看的是短编号(M1、M2…)不是 UUID:省 token,也因为模型抄长串容易抄错一位,抄错就是
  一条改不动的记忆。`MemoryStore` 的排序必须稳定,否则编号会指到别处去。
- 记忆块末尾那句「任何具体数值一律以本次工具返回的为准」是这套东西最要紧的防线,有测试盯着。
  没有它,模型会拿三个月前记下的一句话当今天的数据讲。
- 抽取全程失败即放弃。记忆学不到东西是小事,让保存会话跟着失败是大事。
- **app 侧的测试跑在 app host 里,`MemoryStore.shared` 就是模拟器上那份真的
  `memory.json`**。测试必须走 `MemoryStore(directory:)` / `MemoryTools.registry(store:)` /
  `ChatViewModel(memoryStore:)` 传自己的临时 store——这条踩过一次,一次 `swift test` 把用户
  记住的东西全删了。`SessionStore(parent:)` 和 `ChatViewModel(sessionStore:)` 同理——
  `loadsPersistedSession: false` 只挡住了**写**,而延续线和召回都要去读盘。

**「他总在问什么」不让模型抽**(`InterestProfile`)。那是统计:本地按会话数工具调用,越近的
会话权重越高,一条会话里同一个工具查五次只算一次(那是一个问题拆成五步,不是关心程度是别人
的五倍)。数工具调用而不是问句关键词——「今天不想聊睡眠」也含「睡眠」。模型抽的是他说过的
话,app 数的是他点过的东西,为数数花一次模型调用是纯亏。

兴趣**只做同级裁决**(`HealthSituation.ordered`),不做加权:刚练完永远排在体重变化前面,
哪怕他半年没问过锻炼。做成能翻盘的权重,第一条建议就会开始答非所问。接在 `detect()` 的排序
里,首屏建议、check-in、Siri 三处一起受益——同一份数据在三个地方说出三种结论,用户只会觉得
这 app 自己都没想清楚。

## 隐私对话(`ChatSession.isPrivate`)

一条**不留本机痕迹**的会话。健康 app 里总有几件事人不愿意留下记录,这个开关的全部价值就是
那句承诺可信,所以它是按「有哪些写入路径」定义的,不是按名字:

- 不落盘(`ChatViewModel.saveSession`)。会话文件是所有本机痕迹的源头——不落盘,会话列表和
  `InterestProfile`(只数存下来的会话)就一并没有它。
- 不抽记忆(`MemoryHarvest.shouldHarvest`)。
- 不挂 `remember`(`CapabilityRegistry.healthChat(allowsMemoryWrites:)`)。这条最容易漏:
  抽取被挡住只堵了一条路。
- 分叉出来的还是隐私的;空会话时才能开关,开聊之后就定了。

两条**故意没做**的事:

- **照样读记忆**。承诺的是不往盘上写,不是失忆。把已知的也关掉,用户恰恰在想问私密事的时候
  拿到一个不认识他的助手,那这个开关只会没人用。
- **不暗示端到端隐私**。问题终究要发给用户配置的云端模型才有人回答,`ChatView.privacyNote`
  把这句明写在首屏,图标也用 `eye.slash` 而不是 `lock`(锁在这个语境里读作「加密了」)。
  含糊其辞才是真的逗人玩;写清楚它挡住的是什么,这个开关反而可信。

界面上分两处,别再合回一处:空会话时是输入区上方那颗可点的 chip,开聊之后是导航栏副标题。
开聊之后不留一条不可点的 chip——它和旁边的追问 chip 长得一样,点不动只会让人以为坏了;而
隐私是整条会话的属性,本来就该一直挂在视线里,不是混在一排动作里。

## 架构:跨会话召回(`HealthChat/Recall`)

记忆存「关于这位用户」,召回找回「那次聊出来的结论」。**两件事,不要合并**。

记忆按设计不存数字、不存某一次分析的细节(那条边界是对的)。于是「上个月我们查出来你睡眠差
的那几天都是周三,对上了你说的加班」这类结论无处安放——它会过期,不该进记忆;它又是模型当时
做的归因,重查一遍数据也拿不回来。它属于**那次会话**。`search_sessions` + `read_session`
两个只读工具就是去把它取回来。

胜负手是**召回精度不是召回广度**。模型说「我们上次说过…」而用户根本不记得说过,或者把三个月
前的数字当成本周的讲,那一瞬间信任掉得比从没记住过还快。所以:

- **短编号按 `createdAt` 升序发**(`SessionRecallIndex`)。创建时间永不变,编号只在更早的
  会话被删掉时才动;按 `updatedAt` 排的话随便一次保存就能让上一句说的 S3 指到别处去。
  排除当前会话放在**发号之后**,否则它之后创建的每条都错位一格。
- **检索只打分用户说过的话**,不算助手的回复。助手那几段什么都提一句(「睡眠、心率、活动量
  都还行」),放进来的话每条会话都能匹配上任何查询,检索就退化成按时间倒序。
- **读回来用原文,不重新总结。** 总结要花一次模型调用,而这一步跑在用户已经在等回复的时候。
  装不下就保头保尾(开头是他在问什么,结尾是结论;丢掉的中段是查数据的过程,那本来就该现查),
  中段若有整段摘要 artifact 就用它的 `visibleSummary` 顶上——那是已经算好存下的,白拿。
- **每段标日期,末尾原样带上「数值一律以本次工具返回的为准」**(`SessionRecallTranscript.footer`)。
  和记忆块末尾那句同源,但这里更要紧:记忆里顶多一两句易腐的说法,旧会话里是成篇的过期数字。
- **工具输出里的工具轨迹只留名字不留数字**。查过什么说明结论建立在哪些数据上,有用;带回数字
  等于拿三个月前的 54 污染这一轮。
- 找不到**不报错**。「以前没聊过这个」是有效答案,模型据此就该去查数据;报成错误它会以为工具
  坏了,换个说法再试一次,白花一轮。
- 隐私会话从不落盘,天然不在索引里;删掉的会话必须**立刻**消失(`SessionStore.invalidateCaches`)
  ——用户刚删完还能被引用出来,是这套东西最难解释的一种失灵。
- 归在 `memoryEnabled` 一个开关下面。关掉记忆的人不会指望 Vana 还在引用他上个月说过的话。

**不做的**:为省 context 而 spawn 子会话。工具输出是按天聚合的小数值,信噪比本来就好,
`ContextPolicy` 那四档已经是这个问题的正解;而且用户盯着流式输出,插一个静默二十秒的子会话
是 coding agent 里根本不存在的 UX 成本。也不做多 agent 互相 review——第二个 agent 没有独立
信息源(同一份 HealthKit 数据、同一份记忆、同一个模型),产生的是更谨慎而不是更准的话。

## 架构:延续线与后台派生(`SessionThread` / `FollowUpRunner`)

**延续线**(`ChatSession.threadId`):check-in 通知、到期的待跟进、用户自己开的目标接着上次那条
聊,不每次开新的。在这之前「这件事」散在三十条标题都叫「昨晚睡得怎么样？」的会话里。三条边界:

- **延续有期限**(`SessionThreadPolicy`:4 天没动过、或攒够 40 条就另起一段)。永远接着上一条
  会把它养成一份永不结束的日志——每轮都要压缩一次,用户翻到底要滑半天。断开的那段一条不丢,
  `search_sessions` 照样翻得到,所以断得起。
- **延续线不带话题**。今天问活动量、明天问睡眠;话题写死在 system 段里,聊到第三天就和正在问
  的事对不上了,而中途改它又会让模型对这次对话的认知跳变。重点由那句开场问题自己带。
- **Siri 不接线**,分叉出来的也不继承。前者是一句临时想到的问题,后者两条会话认领同一条线,
  下次接哪条就成了看谁最后更新的。

**目标线**(`SessionThread.goal`)是用户自己开的一件长期的事(减脂、备半马)。和内置那两条的
区别全在「这是他的东西」:

- **名字他起**,存在每一段的 `threadTitle` 上,不另开一张目标表。一段一段往下传看着冗余,
  换来的是名字和内容永远在同一个文件里——删掉最后一段这条线就干净地不存在了,不会剩下一条
  指着空处的定义。改名要**改到每一段**,否则旧的几段会以旧名字留在召回结果里。
- **断得比 check-in 宽**(21 天 vs 4 天)。「减脂」请一周假回来还是同一件事,而每天的 check-in
  隔一周就是新的一段了。
- **列表里按线合并成一行**,并且从下面按时间分的那几组里摘出去。同一条线既排在目标区、又在
  「今天」里出现一遍,用户会以为那是两个东西。删也是整条删。
- 目标名字进 system 段(`AIKitEngine(goal:)`),并明说「眼前这几句可能只是最近的一段,需要就用
  `search_sessions` 往前翻」。不说这一句,模型会把它当成他今天临时想问的事,而不是已经聊了三个
  星期的那件事。目标线同样不给话题。

**后台派生**(`DerivedTurn` + `FollowUpRunner` / `GoalDigest`,由 `BackgroundDigest` 调度):
用户不在场时替他问的一轮。到期的待跟进、目标的周进展都走它,早上那条通知里带的是**结论**而不是
把当初那句话再念一遍。形状照抄 `MemoryExtractor`——它其实已经是第一个子会话了,只是没有会话
身份:非阻塞(跑在切前后台时,不在用户等回复的时候)、独立上下文、**失败即放弃**。

`DerivedTurn` 管怎么跑,`FollowUpRunner` / `GoalDigest` 各管**该不该跑**和**问什么**。

- 这一轮**不能并进 `CheckInScheduler.reschedule()`**:那是完整的模型调用加几轮工具,让通知
  排程等着它,是拿一件确定的事去赌一件不确定的事。跑出结论了再重排一次。
- **一次前后台最多跑一件**。两件都成立时先跑待跟进:那是一个带日子的约定,今天不说就失约了;
  目标的周进展晚一天说没什么损失。连着跑两轮是用户完全没预期的开销,而早上那条通知只有一行。
- 闸要严,因为这是用户不在场时花的钱:没配齐云端设置不跑、关了 check-in 不跑(结论没有送达的
  路子,纯粹花钱写给自己看)、待跟进一天最多一条、目标**一周**一次。
  一周不是一天——入睡时间、体重这类指标的日间波动比趋势本身大,每天报一次说的全是噪声,
  第三天用户就开始无视这条通知了。放下一个月的目标直接不问:那是纠缠不是关心。
- **不给写记忆的口子**(`allowsMemoryWrites: false`)。用户看不见「记住了…」那条气泡,也没法
  当场说一句"别记这个"。读照旧——不认识用户的话这一轮还不如不跑。
- 「跑过没跑过」拿**那条会话**当标记,不另开字段。会话就是这次跑出来的产物;多一个字段就多
  一处能和产物对不上的状态。通知正文也从那条会话读,不存第二份摘要。
- **`ChatSession.isDerived` 分开「他问过什么」和「我们替他问过什么」**。最要紧的一处是
  `InterestProfile`:后台替他查了三次体重不代表他关心体重,而那份统计反过来又会影响后台去查
  什么——不挡住就是自己喂自己。上一份没人接话的进展报告也靠它认出来,由新的顶掉;每周攒一段
  一年就是五十二段,而用户根本没看过前面那些。他一旦回了一句,那段就是真的对话,再也不顶。
- 目标进展在通知里**排在触发点前面、待跟进后面**。理由同「待跟进排在所有触发点前面」:那是
  用户自己定下的事,触发点只是数据里冒出来的现象。没跑出结论就整个不进通知——空口一句
  「你的『减脂』还在进行中」是零信息,不如把位置让给触发点。
- 点开回到哪条线由**排程时**写进 `userInfo.threadId`,不让收件方现算。通知说的是「减脂」、
  点开却落在 check-in,两边谁对谁错没人说得清。

## 会话目录的开销(`SessionIndexEntry` / `SessionStore`)

会话文件是这个 app 里**最大**的一类数据:一轮里两次健康查询的原始输出就有一万多字符,而
`storedTurn.exactTranscript` 会把同样的文本再存一份给模型回放用。而读目录这件事跑在用户已经
在等的时候——每轮回复结束刷一次列表、`search_sessions` 每次调用建一次索引、从 check-in 进 app
找一次延续线。

一年三百条会话,全量解一遍 **380ms / 峰值 +41MB**,而上面三件事各自解一遍。改成三条之后是
**33ms / +0.2MB**,增量刷新 **个位数毫秒**:

1. **只解用得上的键**(`SessionIndexEntry`)。`JSONDecoder` 不会去实例化没声明的字段,省掉的
   正是最大的那半边(`storedTurn`、每份 `HealthReport` 的逐小时序列)。
2. **一次扫描喂三个读者**。列表、召回、延续线、兴趣统计查的是同一份索引。
3. **按文件改动时间增量更新**。一轮回复结束只有一个文件变了,没道理把另外二百九十九条重解一遍。

几条不要破坏的:

- **索引里不留对话全文**。它常驻在 actor 里,而检索只用得上用户说过的话(`userText`,还带上限)
  和几个工具名。跟着把一年的工具输出留在内存里,是为了一个每轮最多用两次的功能付整段内存。
- **标题只有一份算法**(`SessionTitle.make`)。界面走 `ChatSession.title`(手里是整份会话),索引
  走 `SessionIndexEntry`(手里只有几个键)。各写一遍迟早漂,漂的结果是列表上一个名字、召回结果
  里另一个名字。
- **写完必须让缓存失效**。删掉的会话还能被模型引用出来,是这套东西最难解释的一种失灵。
- 读某一条的全文走 `load(id:)`,那是一次一条,该解就解——通知正文要模型真写的那句话,
  索引里没有。

`HealthChatTests/SessionStorePerformanceTests` 盯着耗时和 `phys_footprint` 峰值,改这块先看它。

## 架构:Siri(`HealthChat/Intents`)

四条 App Intent,分成两类,中间**没有第三种形态**:

- `TodayStatusIntent` / `LastNightSleepIntent` / `LastWorkoutIntent` 在后台跑,念
  `SpokenBrief` 本地算出来的一两句话。不联网、不看 API key。让 Siri 等一轮模型调用
  (联网 + 几轮工具 + 流式)只会超时,而超时之后用户听到的是"出了点问题"。
- `AskVanaIntent` 收一个问题参数,`.foreground(.immediate)` 把 app 拉起来,经
  `VanaLaunchRouter` → `CheckInLaunch(autoSend: true)` 进一条新会话,由完整的 agent 回答。
  Siri 和 check-in 通知共用 `openedCheckIn` 这一个入口;多一条路进 app 不该多一套载入逻辑。

几个容易踩的点:

- **不需要 Apple Intelligence**。App Shortcuts 是短语匹配,前提是句子里出现 app 名字
  (`\(.applicationName)`,解析成 Vana)。中国大陆没有 Apple Intelligence,这条路照样能用;
  反过来,"让 Siri 自由多轮代理式对话"那条现在做不了,别往那个方向设计。
- **短语按 app 的开发语言登记**。`project.yml` 里的 `developmentLanguage` 和
  `DEVELOPMENT_LANGUAGE` 都必须是 `zh-Hans`,留在 en 的话 `VanaShortcuts` 里写的中文在中文
  Siri 上一句都匹配不上。验证办法:clean build 的日志里应该有
  `Training '...' for zh-Hans`,产物里应该有 `HealthChat.app/Metadata.appintents/nlu`。
- **后台弹不出授权面板**,所以查之前先 `HealthStore.readAccess()` 问清楚,没授权就照实说
  "先打开 Vana"。锁屏时 HealthKit 整个库读不了(`isDatabaseLocked`),那是另一句话,不是
  "没有数据"。三种读不到的原因分开说,用户才知道下一步该干什么。
- `SpokenBrief` 里取数和组句是分开的:组句是纯函数,`now` / `calendar` 从外面传,
  `SpokenBriefTests` 盯着"昨晚是几天前"和"比平均多还是少"这两处。
- 触发点识别复用 `HealthSituation.detect()`,和 check-in 通知、首屏建议同一套。同一份数据
  在三个地方说出三种结论,用户只会觉得这 app 自己都没想清楚。

## 依赖

云端 LLM 请求走 AIKit(`zjywill/aikitswift`),以本地包 `../aikitswift` 引入——构建这个项目需要旁边有 aikitswift 的 checkout。`AgentRuntime` 是仓库内的本地包,没有外部依赖。

## 约定

- iOS 26 only,不写旧版本可用性分支。
- HealthKit 只读;API key 只进 Keychain。
- 工具只返回按天(或按晚)聚合值,不返回原始样本。逐小时序列只画在结果面板里,不进模型上下文。
