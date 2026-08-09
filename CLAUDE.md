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
