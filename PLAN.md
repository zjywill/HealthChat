# HealthChat 计划

一句话:iOS SwiftUI 聊天 app,agent 自己决定去查 Apple Health 里的什么数据(步数/睡眠/心率…),用对话的形式给你分析。

## 产品形态(首版)

- 打开就是聊天界面,没有仪表盘。你问"我最近睡得怎么样",agent 调用睡眠查询工具拿到近 7 天聚合数据,流式回复分析。
- 回复气泡上方用小字标注这轮调用了哪些健康查询("查询了最近 7 天睡眠"),让数据来源透明。
- 双引擎:
  - **端上模型(默认)**:iOS 26 FoundationModels,免 key、数据不出设备。
  - **云端引擎(AIKit)**:设置里填 API key 后可切换,分析更强,只上传聚合摘要。走自家 [aikitswift](https://github.com/zjywill/aikitswift) 统一 provider 层,默认 anthropic/claude-sonnet-5,catalog 里 49 个 provider 都可选。

## 架构

```
ChatView / ChatViewModel        聊天 UI + 消息流转
        │  reply(to:) → AsyncThrowingStream<AgentEvent>
        ▼
AgentEngine(协议)
 ├─ EchoEngine                  M0 占位,跑通 UI 后删除
 ├─ FoundationModelsEngine      M3:LanguageModelSession + Tool 协议
 └─ AIKitEngine                 M4:AIKit 统一 provider 层(流式 + tool loop 现成)
        │  两个引擎共用同一套工具语义
        ▼
HealthTools                     工具定义(名称/参数/返回格式)一处声明,两边适配
        ▼
HealthStore                     HealthKit 只读封装:授权 + 聚合查询
```

骨架文件对照:

| 文件 | 职责 |
|---|---|
| `HealthChat/HealthChatApp.swift` | 入口 |
| `HealthChat/Models/ChatMessage.swift` | 消息模型(role + 文本 + 工具调用备注) |
| `HealthChat/Chat/ChatView.swift` | 聊天界面(气泡列表 + 输入栏 + 设置入口) |
| `HealthChat/Chat/ChatViewModel.swift` | 发消息、消费引擎事件流 |
| `HealthChat/Engine/AgentEngine.swift` | 引擎协议 + `AgentEvent`(textDelta / toolCall)+ 错误 |
| `HealthChat/Engine/EchoEngine.swift` | 占位引擎 |
| `HealthChat/Engine/FoundationModelsEngine.swift` | 端上引擎(M3 实现) |
| `HealthChat/Engine/AIKitEngine.swift` | 云端引擎,走 AIKit(M4 实现) |
| `HealthChat/Engine/HealthTools.swift` | 工具集定义(M3/M4 实现) |
| `HealthChat/Health/HealthStore.swift` | HealthKit 读取层(M2 实现) |
| `HealthChat/Settings/SettingsView.swift` | 引擎选择 + API key(M4 实现) |

## 工具集设计(M3/M4 共用语义)

所有工具只返回**聚合值**(按天汇总),不返回原始样本——既省 token 也是云端路径的数据最小化。语义一处声明,两边适配:FoundationModels 用 `Tool` 协议,AIKit 用 `ToolDefinition`(JSON Schema)。

| 工具 | 参数 | 返回 |
|---|---|---|
| `daily_steps` | days (1–90) | 每日步数 + 均值 |
| `sleep_summary` | days | 每晚时长/入睡起床时间 + 均值 |
| `heart_rate_summary` | days | 每日静息心率、HRV、心率区间 |
| `workouts` | days | 锻炼列表(类型/时长/消耗) |
| `body_metrics` | days | 体重/体脂趋势 |

## 引擎选择策略

启动时自动选:端上模型可用(`SystemLanguageModel.default.availability`)→ 端上;不可用但有 API key → 云端(AIKit);都没有 → 聊天区显示引导。设置里可手动覆盖。

## 关键决定

- **iOS 26 only**,单 target iPhone。FoundationModels 需要 26,不做旧版本兼容,代码干净。
- **HealthKit 只读**,不申请写权限(DEBUG 种子数据除外,见风险)。
- **API key 存 Keychain**,不进 UserDefaults。
- 云端请求不手写:用自家 AIKit(本地包 `../aikitswift`),流式事件、tool loop、多轮 replay 都是现成的。默认 anthropic/`claude-sonnet-5`,provider 和模型设置里可换。
- 两个引擎都走流式,UI 层只认 `AgentEvent`,不感知引擎差异。

## 里程碑

- **M0 骨架(本次)**:xcodegen 工程 + 全部 stub 文件编译通过,Echo 引擎跑通聊天 UI。✅ 验收:模拟器能聊天回显。
- **M1 权限与授权流**:首次进入请求 HealthKit 读权限,拒绝态的引导 UI。
- **M2 HealthStore 查询**:五个聚合查询实现 + 模拟器样本数据方案。
- **M3 端上 agent**:FoundationModels 接入,Tool 协议实现五个工具,系统 instructions(健康分析人设、单位、克制不诊断)。
- **M4 云端引擎(AIKit)+ 设置页**:`AIClient.stream` 接入、`ToolDefinition` 映射、`pendingToolCalls` 续轮循环、Keychain 存 key、provider/模型/引擎切换。
- **M5 打磨**:回复 Markdown 渲染、对话历史持久化、必要时 Swift Charts 小图表嵌入回答。

每个里程碑在模拟器跑通 + 截图验证后再进下一个(一次一个可见改动)。

## 风险与对策

- **模拟器上 FoundationModels**:需要宿主 Mac 开启 Apple Intelligence;不可用时引擎自动回落到云端/引导,不能 crash。
- **本地包依赖**:AIKit 以 `../aikitswift` 同级 checkout 引入,克隆 HealthChat 需要旁边有 aikitswift;aikitswift 打 tag 后可改成远程依赖。
- **模拟器 Health 没数据**:方案 A 在模拟器 Health app 里手动加样本;方案 B DEBUG-only 种子写入(需临时申请写权限,仅 DEBUG 编译)。M2 时定。
- **FoundationModels 上下文小(约 4k token)**:对话历史裁剪 + 工具返回保持紧凑(这也是只返回聚合值的原因之一)。
- **真机部署**:需要签名 team + HealthKit capability;真机才有真实健康数据,M3 后建议真机跑。
- **健康分析的边界**:instructions 里明确不做医疗诊断,异常数据建议就医。

## 未定问题(不阻塞骨架)

- App 名字:暂用 HealthChat,随时可改。
- 是否要对话历史持久化、图表:M5 再定。
- 测试 target:M2 引入(HealthStore 聚合逻辑值得测),M0 不建。
