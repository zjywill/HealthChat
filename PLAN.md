# Vana 计划与任务拆分

一句话:iOS SwiftUI 聊天 app,agent 自己决定去查 Apple Health 里的什么数据(步数/睡眠/心率…),用对话的形式给你分析。

本文档是执行清单:任务按 T 编号严格排序,每个任务自包含(目标/改动文件/API 要点/验收)。执行者(Codex 或任何 agent)从「给执行者的须知」读起,一次做一个任务。

## 给执行者的须知

**仓库现状**:M0 骨架已完成——xcodegen 工程、聊天 UI、`AgentEngine` 协议、三个引擎壳(Echo 占位可跑)、`HealthStore` 空壳、设置页空壳,模拟器编译通过。你从 T1.1 开始。

**工作方式**:
- 严格按编号顺序,一次一个任务。做完一个:构建通过 → 按该任务「验收」验证 → commit(message 以任务号开头,如 `T2.1: …`)→ 再进下一个。
- `project.yml` 是工程唯一事实来源,**不要手改 xcodeproj**;增删文件后跑 `xcodegen` 重新生成。
- 不新增第三方依赖(唯一依赖是本地包 `../aikitswift`,已挂好)。AIKit 的 API 拿不准就直接读 `../aikitswift/Sources/AIKit/Spec/` 的源码,别猜。
- iOS 26 only,不写 OS 版本可用性分支(FoundationModels 的**运行时**可用性检查除外,那是另一回事)。
- UI 文案用中文。写码风格跟随现有文件(注释密度低、中文注释)。
- 本文档里的 SDK 签名凭印象写就,细节以编译器报错为准;意图不变,签名可调。

**构建/运行命令**:

```bash
xcodegen   # 仅在增删文件后需要
xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet
```

装进模拟器手测:

```bash
APP=$(xcodebuild -project Vana.xcodeproj -scheme Vana \
  -destination 'platform=iOS Simulator,name=iPhone 17' -showBuildSettings 2>/dev/null \
  | awk '/ BUILT_PRODUCTS_DIR =/{d=$3} / FULL_PRODUCT_NAME =/{n=$3} END{print d"/"n}')
xcrun simctl install booted "$APP"
xcrun simctl launch booted com.pinapia.vana.ios
```

**已配好、不要重复配**:HealthKit read entitlement、`NSHealthShareUsageDescription`、bundle id `com.pinapia.vana.ios`。

## 产品形态

- 打开就是聊天界面,没有仪表盘。你问"我最近睡得怎么样",agent 调用睡眠查询工具拿近 7 天聚合数据,流式回复分析。
- 回复气泡上方小字标注这轮调用了哪些查询("查询了最近 7 天睡眠"),数据来源透明。UI 已在 M0 做好(`ChatMessage.toolNotes`)。
- 引擎:**云端 AIKit(填 key 后可用,默认 anthropic/claude-sonnet-5,目录里 44 个云端 provider 可选)**。
- **端上 FoundationModels 引擎已于 2026-08-08 暂时移除**(体验没达到可用标准,先不做卖点):`FoundationModelsEngine.swift` 连同引擎选择 UI 一起删掉,代码在 commit `6dba4fe`(T3.4)里,要加回来直接从那儿取。M3 的任务描述保留在下面备查。

## 架构

```
ChatView / ChatViewModel        聊天 UI + 消息流转(M0 已有)
        │  reply(to:) → AsyncThrowingStream<AgentEvent>
        ▼
AgentEngine(协议,M0 已有)
 ├─ EchoEngine                  占位,T4.5 删除
 ├─ FoundationModelsEngine      T3.x
 └─ AIKitEngine                 T4.x
        ▼
HealthToolSpec × 5              工具语义一处声明(T3.1),两边适配
        ▼
HealthStore                     HealthKit 只读聚合查询(T1–T2)
```

## 工具集契约

七个工具,参数统一只有 `days`(整数 1–90,默认 7)。所有工具返回**紧凑中文文本**(不是 JSON):按天聚合值,不含原始样本——省 token,也是云端路径的数据最小化。description 必须写明触发条件("当用户问及步数/活动量时调用"),这是模型肯不肯用工具的主要杠杆。

| 工具名 | 数据 | 输出要点 |
|---|---|---|
| `daily_steps` | 每日步数 | 逐日列表 + 均值,`08-01 8,432 步` 风格 |
| `sleep_summary` | 每晚睡眠 | 逐晚时长/入睡/起床 + 均值时长 |
| `heart_rate_summary` | 静息心率 + HRV | 逐日静息心率、HRV(SDNN)+ 区间 |
| `workouts` | 锻炼记录 | 逐条:日期/类型/时长/消耗 kcal |
| `body_metrics` | 体重/体脂 | 逐日(有记录的天)+ 首尾变化 |
| `blood_pressure` | 收缩压/舒张压 | 逐日均值 `112/74 mmHg` + 区间均值 |
| `vitals` | 血氧/呼吸频率/体温 | 逐日均值,缺哪项省哪项 |

后两个多数人没有数据(血压要血压计,血氧和手腕温度要够新的 Apple Watch)。**没有记录不是错误**:工具照实说没有并给出补上的办法,`HealthStore` 把 HealthKit 的授权错误也当成"没有数据"处理——否则模型会把"没允许读"报成"查询失败"。授权照常申请:申请本身不要求有数据,以后用户真记了就直接能读。

## 引擎选择策略(T4.5 实现,端上移除后简化)

只剩云端一条路:每次发送时读 Keychain,没 key 抛 `needsAPIKey`、没选模型抛 `needsModelSelection`,欢迎卡提示去设置配置。端上引擎加回来时再恢复「自动/端上/云端」三选。

---

## 任务列表

### M1 授权流

**T1.1 HealthStore:类型集合与授权请求**
- 文件:`Vana/Health/HealthStore.swift`
- 读类型集合:`HKQuantityType(.stepCount)`、`.restingHeartRate`、`.heartRateVariabilitySDNN`、`.activeEnergyBurned`、`.bodyMass`、`.bodyFatPercentage`,`HKCategoryType(.sleepAnalysis)`,`HKObjectType.workoutType()`。
- `requestAuthorization()`:先 `HKHealthStore.isHealthDataAvailable()`,再 `try await store.requestAuthorization(toShare: [], read: readTypes)`。
- **坑**:HealthKit 隐私设计决定**读权限的拒绝状态不可查询**(`authorizationStatus` 只反映写权限)。不要试图判断"用户拒绝了读";统一用"查询结果为空 → 提示去 设置 > 隐私与安全性 > 健康 检查授权"。
- 验收:见 T1.2(一起手测)。

**T1.2 启动请求授权 + 空态欢迎卡**
- 文件:`ChatView.swift`、`ChatViewModel.swift`
- `ChatView` 出现时(`.task`)调 `HealthStore.shared.requestAuthorization()`,失败静默(console 打印即可)。
- `messages` 为空时聊天区显示欢迎卡:app 是干嘛的、会读哪些数据、给 3 个示例问题(点击即填入输入框发送)。
- 验收:删掉 app 重装(`xcrun simctl uninstall booted com.pinapia.vana.ios`),首启弹 HealthKit 授权面板,全选允许;空态卡片显示,点示例问题能发出去(Echo 回显)。

### M2 查询层(先做种子数据,后面每个查询都能立即验证)

**T2.1 DEBUG 种子数据 + 自检面板**
- 文件:新建 `Vana/Health/DebugSeeder.swift`,`SettingsView.swift` 加入口
- 整个文件 `#if DEBUG` 包裹。`seed()`:额外请求这些类型的**写**权限(仅种子用),写入最近 30 天合理假数据:步数(4k–15k/天)、睡眠(23:00±1h 入睡、7±1h 时长,拆 core/deep/REM 段)、静息心率(55–70)、HRV(30–80ms)、每周 3 次锻炼(跑步/骑行,30–60min,含 activeEnergyBurned 关联样本)、体重(70±0.5kg 缓慢下降)、体脂(20±1%)。
- 设置页 DEBUG section:「写入种子数据」和「自检查询」按钮;自检跑通全部查询并把结果 `print` 到 console(T2.2 起逐个补)。
- 验收:模拟器点种子 → iOS 健康 app 里能看到数据;重复点不崩(允许重复写入)。

**T2.2 dailySteps**
- 文件:`HealthStore.swift`
- `func dailySteps(days: Int) async throws -> [DayValue]`,`DayValue { date: Date; value: Double }`。
- 用 `HKStatisticsCollectionQueryDescriptor`(cumulativeSum,anchor 当天 `startOfDay`,interval 1 天),`try await descriptor.result(for: store)`,遍历取 `sumQuantity()?.doubleValue(for: .count())`。
- 验收:自检打印 7 天步数,与健康 app 对得上。

**T2.3 sleepSummary**
- `func sleepSummary(days: Int) async throws -> [NightSleep]`,`NightSleep { night: Date; asleep: TimeInterval; bedtime: Date?; wake: Date? }`。
- `HKSampleQueryDescriptor` 取 `sleepAnalysis` 样本;**按晚分桶用中午 12 点为界**(样本跨午夜);`asleep` 只累加 `asleepCore/asleepDeep/asleepREM/asleepUnspecified`(`inBed` 不算);bedtime = 当晚最早样本 start,wake = 最晚样本 end。
- 验收:自检打印 7 晚,时长 6–8h 合理。

**T2.4 heartRateSummary**
- `func heartRateSummary(days: Int) async throws -> [DayHeart]`,`DayHeart { date; restingHR: Double?; hrv: Double? }`。
- 两个 `HKStatisticsCollectionQueryDescriptor`(discreteAverage):restingHeartRate 单位 `HKUnit.count().unitDivided(by: .minute())`,HRV 单位 `.secondUnit(with: .milli)`。
- 验收:自检打印,数值在种子范围内。

**T2.5 workouts + bodyMetrics**
- `func workouts(days: Int) async throws -> [WorkoutItem]`:`HKSampleQueryDescriptor` 取 `HKWorkout`,输出类型名(`workoutActivityType` 映射中文:跑步/骑行/步行/力量…default 其它)、时长、消耗。**坑**:`workout.totalEnergyBurned` 已废弃,用 `workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()`。
- `func bodyMetrics(days: Int) async throws -> [DayBody]`:bodyMass(kg)、bodyFatPercentage(%),discreteAverage 按天,无记录的天跳过。
- 验收:自检打印锻炼列表和体重曲线。

### M3 端上引擎(FoundationModels)——**已实现后又暂时移除,等要用时按下面的描述从 `6dba4fe` 恢复**

**T3.1 HealthToolSpec:中立工具定义**
- 文件:重写 `Vana/Engine/HealthTools.swift`
- ```swift
  struct HealthToolSpec: Sendable {
      let name: String          // "daily_steps"
      let description: String   // 含触发条件
      let run: @Sendable (_ days: Int) async throws -> String  // 紧凑中文文本
  }
  ```
- `HealthTools.all: [HealthToolSpec]` 五个实例,`run` 调 HealthStore 并渲染文本(日期 `MM-dd`,时长 `x小时x分`,千分位步数)。渲染函数放同文件。空结果返回"最近 N 天没有××记录"。
- 验收:自检面板改为遍历 `HealthTools.all` 逐个 `run(7)` 打印,肉眼检查文本紧凑可读。

**T3.2 FoundationModelsEngine:无工具对话跑通**
- 文件:`FoundationModelsEngine.swift`、`ChatViewModel.swift`(临时把引擎换成它)
- `import FoundationModels`。可用性:`SystemLanguageModel.default.availability`,非 `.available` 抛 `AgentError.modelUnavailable`。
- 会话:`LanguageModelSession(instructions:)`。**引擎持有 session 作实例状态**(它自带 transcript,多轮只发新消息),所以 `FoundationModelsEngine` 改成 `final class`,`reply` 只取 `history` 最后一条 user 文本。
- 流式:`session.streamResponse(to: text)` 迭代出的是**累积快照不是增量**——保留上一份,发 `textDelta(新内容去掉已发前缀)`。
- 错误:`exceededContextWindowSize` → 重建 session(带 instructions,不带旧史)重试一次;guardrail 拒绝 → 友好文案。
- 验收:模拟器(宿主 Mac 需开 Apple Intelligence)问"你好,你能干什么",流式出中文回复。不可用的机器上显示 modelUnavailable 文案、不崩。

**T3.3 挂上五个工具**
- 文件:`FoundationModelsEngine.swift`
- 每个 spec 包一个 FoundationModels `Tool`:`name`/`description` 来自 spec;`Arguments` 用 `@Generable struct { @Guide(description: "查询最近多少天,1-90") var days: Int }`;`call` 里执行 `spec.run(days)` 返回 `ToolOutput`,并通过注入的回调把"查询了最近 N 天××"发成 `AgentEvent.toolCall`(回调在每次 `reply` 开始时指向当前 continuation)。
- session 用 `LanguageModelSession(tools: …, instructions: …)` 创建。
- 验收:问"我最近一周睡得怎么样",气泡上方出现工具备注,回复内容引用了种子数据的真实数字(对照自检输出)。
- **上下文预算**:端上模型窗口约 4k token,这也是工具输出必须紧凑的原因;`days` 大时截断输出行数(>30 天改为只给周汇总)。

**T3.4 instructions 定稿**
- 中文健康助手人设:回答基于工具返回的真实数据,不编造数字;单位习惯(步/小时分钟/次每分/kg);语气克制,**不做医疗诊断**,数据异常建议就医;回答先结论后数据。
- 验收:三个问题走查(睡眠/步数/综合"我最近状态怎么样"),回复引用真实数字、不越界诊断。

### M4 云端引擎(AIKit)+ 设置页

**T4.1 KeychainStore**
- 新建 `Vana/Settings/KeychainStore.swift`:`kSecClassGenericPassword`,service `com.pinapia.vana.ios`,`get/set/delete(account:)`,set 用先删后加实现 upsert。只存 API key;provider id / model 名不是秘密,走 `@AppStorage`。
- 验收:编译过;T4.4 一起手测。

**T4.2 AIKitEngine:无工具流式跑通**
- 文件:`AIKitEngine.swift`
- `import AIKit`(已 import)。key 无 → 抛 `AgentError.needsAPIKey`。
- `AIClient(providerId: providerId, configuration: .init(apiKey: key))`;`CallOptions(model: model, prompt: prompt)`,prompt 由 `[ChatMessage]` 映射:`[.system(instructions)] + history.map { $0.role == .user ? .user($0.text) : .assistant($0.text) }`(instructions 与 T3.4 同一份,抽到公共位置)。
- `for try await part in try client.stream(options)`:`case .textDelta(_, let delta, _)` → `AgentEvent.textDelta`;其余 default 忽略。`AIClientError` 的 `errorDescription` 已经人话,直接透出。
- 验收:设置里填真 key(手测者自己的),强制云端引擎,问答流式正常。
- 参考:`../aikitswift/README.md` 和 `Sources/AIKit/Spec/`。

**T4.3 AIKitEngine:tool loop**
- `CallOptions.tools = HealthTools.all.map { ToolDefinition(name:description:inputSchema:) }`,schema 用 `JSONValue`(支持字典/字符串字面量):`.object(["type": "object", "properties": .object(["days": .object(["type": "integer", "description": "查询最近多少天,1-90"])]), "required": .array(["days"])])`。
- 循环(最多 6 轮):流式转发 `textDelta` 的同时把所有 part 收进数组 → `AIResponse(parts: parts)` → `pendingToolCalls` 为空则结束;否则 `prompt.append(response.assistantMessage)`,逐个 call:发 `AgentEvent.toolCall(中文描述)`,`call.input` 是 **JSON 字符串**,解析出 `days`(缺省 7),`spec.run(days)`,`prompt.append(.toolResult(toolCallId: call.toolCallId, toolName: call.toolName, result: .string(文本)))`,再进下一轮。
- 验收:云端引擎问"最近一周睡眠和运动怎么样",看到 ≥1 条工具备注,回复引用真实数字。
- 数据边界:上传的只有工具返回的聚合文本(契约保证),不传原始样本。

**T4.4 SettingsView 定稿**
- 引擎 Picker:自动/端上/云端(`@AppStorage("engineChoice")`);云端 section:`SecureField` API key(失焦或提交时写 Keychain,显示"已保存"态)、provider 与 model **从 AIKit catalog 里选,不让用户手输名字**(`ProviderCatalog.all`,带搜索;只列填 key 就能连的云端 provider——本地部署(Ollama、LM Studio)和目录里没有 `api` 地址的(custom-provider、DimCode OAuth、google)一律过滤掉,44 个;model 只列 `supportsTools` 的;换 provider 自动换成新 provider 的默认模型);catalog 里没有内置模型的 provider(Ollama、各类网关)提供「从服务端获取模型列表」(`AIClient.models()`)和自定义 model ID 兜底;当前生效引擎的展示行。
- 验收:填 key → 杀 app 重开还在;改 provider/model 生效。

**T4.5 引擎自动选择 + 删 Echo**
- `ChatViewModel.send()` 每次现算引擎(策略见上文);删除 `EchoEngine.swift`,欢迎卡在"两个引擎都不可用"时提示去设置填 key 或开 Apple Intelligence。
- 验收:模拟器上分别验证三种路径(自动→端上;强制云端;清 key + 关 AI → 引导文案)。

### M5 打磨(每个可独立做)

**T5.1 Markdown 渲染**:assistant 气泡用 `Text(AttributedString(markdown:))`(失败回退纯文本),多段落保留空行。用 `.inlineOnlyPreservingWhitespace`——`.full` 会按 CommonMark 折叠单换行,模型列的每日数据会糊成一坨。
**T5.2 会话持久化**:一条会话一个文件,`Documents/sessions/<id>.json`(`ChatSession`:messages + createdAt/updatedAt,标题取首条用户消息)。启动载入最近一条,每轮结束落盘,空会话不落盘。聊天页工具栏有「会话列表」和「新对话」,列表页可切换、左滑删除;设置页「清空对话」删掉当前这条。
**T5.5 agent loop 上下文保真**:`ChatMessage.toolCalls` 存下每次工具调用的 id/name/input/output,`makePrompt` 把上几轮的 `tool_use` + `tool_result` 一起回放,模型追问时不必重查;失败的回合整轮不回灌(那段"无法回复：…"是 app 写给用户的,且带一个没有结果的 tool_use 回去 provider 会拒收)。工具行在气泡上方显示,点开看数据(见 T5.11)。
**T5.7 会话话题**:新会话可以先点一个话题(`ChatTopics`:跑步/骑行/力量训练/游泳/步行徒步/瑜伽拉伸/高强度间歇 + 睡眠/心率与 HRV/日常活动量/体重与体脂/整体状态)。话题只做一件事——把一句 `focus` 写进系统提示,告诉模型这次围绕什么、优先调哪个工具、按什么口径回答;工具本身不变。选中后首屏问题立刻换成该话题的三条(本地文案,不花模型调用)。话题存在 `ChatSession.topicId`(只存 id,文案随版本改),开聊后在输入框上方显示;只在会话还空着时可改——聊到一半换话题上下文就对不上了。
**T5.6 首屏问题建议**:三级降级,越往上越个性化,任何一级失败都还有下一级顶着。
1. **时段默认**(`SuggestedQuestions`):早上问昨晚睡眠,下午问活动量与恢复,晚上问今天动够没有。没数据没 key 也有。
2. **本地处境判定**(`HealthSituation.detect()`,纯 HealthKit 查询):刚练完(3 小时内)、昨晚比 14 天常态少睡 45 分钟以上、昨晚无记录、静息心率高出基线 3 次以上、HRV 低于基线 15%、今天 0 步、今天步数超基线 1.5 倍、连续 3 天步数不到基线六成、5 天以上没锻炼、两周体重变化超 1 公斤、入睡时间比上周晚 40 分钟以上、周一早上回顾。按「多可能是此刻打开 app 的原因」排序,时段会调权(早上睡眠优先,晚上活动量优先)。
3. **模型润色**(`QuestionSuggester`):把排好序的处境和最近 7 天摘要交给模型写成三句人话,每次启动只调一次;解析不出三条就退回第 2 级。生成的用 `sparkles` 图标。

每条问题限一行(`lineLimit(1)` + `minimumScaleFactor`)。等待首字时气泡显示三点脉冲(`TypingIndicator`),reduce motion 下退成"正在回复…"。
**T5.3 交互细节**:`.scrollDismissesKeyboard(.interactively)`;回复中把发送按钮换成停止(取消当前 Task,已收内容保留);错误消息气泡带「重试」。
**T5.11 工具结果:结构化 + 底部面板**:工具不再返回一段文本,而是返回 `HealthReport`(title/columns/rows/summary/notes/series)。喂模型的 `modelText` 由同一份结构生成(表头一行 + `|` 分隔的数据行),面板画的是同一批数字——两边分开写迟早对不上。气泡上方的工具行变成 chip,点开是 `.sheet`(medium/large detent):摘要卡 + 表格(日期列钉住,数值横向滚)+ 日内分布柱状图 + 「模型收到的原文」。`ToolCallRecord.report` 跟着会话落盘,旧会话没有这个字段就退回显示文本。
顺带补了颗粒度:睡眠给分期(深/核心/REM)、清醒时长、醒来次数、睡眠效率和睡眠期间心率;心率给全天最低/最高/平均;锻炼给距离和平均/最高心率;活动量给距离、爬楼和运动分钟。逐小时序列只进面板不进 `modelText`——24 个点对端上 4k 的窗口太贵,模型要的是结论不是曲线。
**T5.12 每条回复的操作:复制 / 重新回答 / 分支**:复制按钮直接摆在回复下面(最常用的那个不值得多点一下);重新回答、在新对话里分支,和这条回复的时间收进「…」菜单。
重新回答对**任意一条**回复都生效,不只是最后一条:从那条开始后面整段丢掉再重新生成。不做"保留旧版本、左右切页"那套——想留着旧的走分支,那本来就是分支的意思。分支把到那条为止的消息拷进一条新会话,原会话原样留在列表里;临时会话分叉出来的还是临时的。
`ChatMessage.createdAt` 是后加的字段,旧会话里没有(可空),菜单里就不显示时间——比编一个时间强。
**T5.4(可选)真机验证**:真机跑通全流程(真数据、Apple Intelligence),记录签名 team 步骤到 CLAUDE.md。

### M6 跨会话召回(session 读 session)

**为什么**:现在跨会话只有 `MemoryStore` 一条通道,而它按设计不存数字、不存某一次分析的细节。
结果是「上个月我们查过,你睡眠差的那几天都是周三,对上了你说的加班」这类**结论**无处安放——
它不是关于用户的长期事实(会过期,不该进记忆),也不是能重查的数据(那是模型在那次对话里做的
归因)。它属于**那次会话**。让模型能检索并读回旧会话,是在不破坏记忆边界的前提下把它找回来。

胜负手是**召回精度不是召回广度**:模型说「我们上次说过…」而用户根本不记得说过,或者把三个月
前的睡眠时长当成本周的讲,那一瞬间信任掉得比从没记住过还快。宁可少想起来,不能想错。

**T6.1 `SessionRecall`:索引与摘要**
- 新建 `Vana/Recall/SessionRecall.swift`。短编号 `S1`、`S2`…**按 `createdAt` 升序**分配
  (创建时间永不变,所以编号稳定;按 `updatedAt` 排会在任意一次保存后错位,上一句说的 S3 就
  指到别处去了)。理由和记忆的 `M1`/`M2` 一样:省 token,且模型抄 UUID 容易抄错一位。
- 检索纯本地:标题 + 用户说过的话 + 话题名 + 用过的工具标签,中文按 2-gram 打分。
  不做 embedding——几十条会话,一次目录扫描就够,和 `InterestProfile` 共用同一次扫描。
- 读取用**原文**而不是重新总结(模型调用会让用户干等);超长时保头保尾,中段若有整段摘要
  artifact 就用它的 `visibleSummary` 顶上——那是已经算好存下的,白拿。
- `SessionStore` 补 `init(directory:)`:测试跑在 app host 里,`.shared` 就是模拟器上那份真数据。
- 验收:编号在会话保存后不变;隐私会话(从不落盘)和已删会话都不在索引里。

**T6.2 `search_sessions` / `read_session` 两个只读工具**
- 新建 `Vana/Recall/SessionRecallTools.swift`,形状照 `MemoryTools`。
- 挂在 `CapabilityRegistry.healthChat` 上,受 `memoryEnabled` 管——关掉记忆的人不会指望
  Vana 还在引用他上个月说过的话。关掉时**不挂出去**,不给一个只会报错的工具。
- 排除**当前会话**:否则模型会把正在进行的这条读回来。
- 每段标日期;输出末尾原样带上「任何具体数值一律以本次工具返回的为准」——旧会话里全是过期
  数字,这条防线比在记忆里更要紧。
- 验收:问「上次我们说我睡眠差是因为什么」,能翻到那条会话并引用结论,数字重新查过。

**T6.3 界面**
- 气泡 chip:`search_sessions` → 「翻了翻过往对话」,`read_session` → 「回顾了 7月2日 的对话」,
  图标 `clock.arrow.circlepath`。点开面板显示模型收到的原文(没有 `HealthReport` 时的既有回退)。

### M7 长期目标会话

check-in 通知、Siri、`followUp` 到期现在各开一条新会话,结果是「减脂这件事」散在三十条标题
都叫「今天怎么样」的会话里。把它们汇进**一条长期存在、可被外部写入的会话**,用户第一次能看到
一件事的连续过程。这是 M6 最该被读到的对象。

### M8 后台派生会话

`followUp` 到期时在后台自己跑一轮,产出一条通知(「说好两周后看你的静息心率,现在回落到 54 了」)。
形状照抄 `MemoryExtractor`——它其实已经是第一个子会话了,只是没有会话身份:后台跑、独立上下文、
**失败即放弃**。关键性质是**非阻塞**:不在用户等回复的时候跑。

不做的:为省 context 而 spawn 子会话(工具输出是按天聚合的小数值,信噪比本来就好,
`ContextPolicy` 那四档已经是这个问题的正解),以及多 agent 互相 review/辩论(第二个 agent
没有独立信息源——同一份 HealthKit 数据、同一份记忆、同一个模型,产生的是更谨慎而不是更准的话,
代价是双倍延迟)。

## 备选(想清楚了但**现在不做**)

**同步子 session**——这一轮里 fork 一条、等它跑完、把结论收回来接着说。

机制已经现成:`DerivedTurn.run` 就是 spawn 原语,改个调用方式就能同步跑。缺的不是能力,是
它在**手机上**划不来:

- 子 agent 在 coding agent 里赢,靠的是「中间产物几万 token、结论三行」。健康工具返回的是
  按天聚合的几行数字,信噪比本来就好,`ContextPolicy` 那四档已经是这个问题的正解。
- 手机不会拥有那么大的上下文,也没有那么多可烧的窗口。
- 用户盯着流式输出。插一条静默二十秒的子会话,和卡死是一模一样的观感——这个成本在
  coding agent 里根本不存在。

**已经能用的替代**:模型调 `remember(kind: "followUp", days: N)`,`FollowUpRunner` 到期时会用
`DerivedTurn` 跑出一条完整会话。也就是说模型已经能**排一条延后的 session**,只是没叫这个名字。

真要做的触发条件:出现了需要打十几轮工具才能回答的问题(比如「三个月的睡眠和运动做相关性
分析」)。那时候隔离上下文才开始划算,而且得先解决 UX——让用户看见「正在后台细查…」,
不是干等。

---

## 风险备忘

- **模拟器 FoundationModels**:需宿主 Mac 开启 Apple Intelligence 且模型下载完成;`availability` 给出的 unavailable 原因要透出到 UI,不能 crash。
- **端上上下文 ~4k token**:工具输出紧凑(T3.3 预算规则)、对话史不回灌(session 自带 transcript)。
- **本地包依赖**:构建需要 `../aikitswift` 同级 checkout;aikitswift 打 tag 后可改远程依赖。
- **健康边界**:instructions 明确不做医疗诊断(T3.4)。
- **真机**:需要签名 team;真实健康数据只在真机上有。
