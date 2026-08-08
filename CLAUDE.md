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

## 运行

模拟器安装运行用 iOS Simulator MCP 的 build/launch(bundle id `com.junyizhang.HealthChat`),先 attach 让用户看到面板。

## 依赖

云端 LLM 请求走 AIKit(`zjywill/aikitswift`),以本地包 `../aikitswift` 引入——构建这个项目需要旁边有 aikitswift 的 checkout。

## 约定

- iOS 26 only,不写旧版本可用性分支。
- HealthKit 只读;API key 只进 Keychain。
- 工具只返回按天(或按晚)聚合值,不返回原始样本。逐小时序列只画在结果面板里,不进模型上下文。
