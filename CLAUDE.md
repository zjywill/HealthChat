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

`AgentLoop` 在这两者之上跑工具循环。上下文管理是它最要紧的部分,从轻到重四档:

1. **整段摘要**(`ModelSummarizer`)——估算跨过 `compactionThreshold`(默认预算的 80%)就叫
   模型把远处那段写成 artifact。**发请求之前**做,不是撞墙之后:撞墙时已经没有从容处理的
   余地了。artifact 通过 `.historyCompacted` 事件交回 app 存盘,下轮直接复用,不重算。
2. **逐轮压缩**(`TranscriptCompactor`)——把某一轮的原始工具输出换成它的摘要形态。总结失败
   时也退回这一档,绝不让用户这一句问不出去。
3. **丢最老的一轮**——前两档都不够时的最后手段。
4. 还塞不下就报 `contextWindowExceeded`,不偷偷发一个超长 prompt 出去。

最近 `preservedRecentTurns`(默认 2)轮在第 1、2 档里受保护:刚查完的数据被压成一句摘要,
用户下一句「那第三天呢」就答不上来了。只有真超预算才动它们。

`ContextCalibration` 按 provider+model 归档本地估算和实际计费的比值,换模型即作废。

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

## 依赖

云端 LLM 请求走 AIKit(`zjywill/aikitswift`),以本地包 `../aikitswift` 引入——构建这个项目需要旁边有 aikitswift 的 checkout。`AgentRuntime` 是仓库内的本地包,没有外部依赖。

## 约定

- iOS 26 only,不写旧版本可用性分支。
- HealthKit 只读;API key 只进 Keychain。
- 工具只返回按天(或按晚)聚合值,不返回原始样本。逐小时序列只画在结果面板里,不进模型上下文。
