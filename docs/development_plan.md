# BattleLM - 详细开发规划 v2

## 项目信息

| 项目 | 信息 |
|------|------|
| 项目名称 | BattleLM |
| 平台 | macOS 13.0+ |
| 语言 | Swift 5.9 |
| UI 框架 | SwiftUI |
| 终端库 | SwiftTerm |
| 开发者账号 | Apple Developer Program ($99) |
| 预计开发周期 | 8-10 周 |

---

## 核心技术验证 (Spike) - 开发前必做

### Spike 1: SwiftTerm 集成验证 (1-2 天)

**目标**：验证 SwiftTerm 能否在 App 内显示多个终端

```swift
// 验证代码
import SwiftTerm

let terminal1 = LocalProcessTerminalView(frame: .zero)
terminal1.startProcess(executable: "/bin/zsh")
terminal1.send(txt: "echo 'Hello from Terminal 1'\n")

let terminal2 = LocalProcessTerminalView(frame: .zero)
terminal2.startProcess(executable: "/bin/zsh")
terminal2.send(txt: "gemini\n")
```

**验证标准**：
- [ ] 能同时显示 3+ 个终端视图
- [ ] 每个终端独立运行 shell
- [ ] 能启动 AI CLI (gemini/claude/codex)

### Spike 2: 响应边界检测 (1-2 天)

**目标**：确认能准确识别 AI 回复的开始和结束

**验证标准**：
- [ ] send(prompt) 后能可靠检测到响应完成
- [ ] 能提取纯文本响应（无 UI 污染）
- [ ] 超时处理正常

### Spike 3: 多进程消息路由 (1 天)

**目标**：验证消息能在多个 AI 间路由

**验证标准**：
- [ ] 用户消息能同时发给 3 个 AI
- [ ] 每个 AI 的响应能正确收集
- [ ] 不会混淆不同 AI 的响应

---

## Phase 1: 项目初始化 (第 1 周)

### 1.1 创建 Xcode 项目

```
1. Xcode → File → New → Project
2. macOS → App
3. Product Name: BattleLM
4. Team: 你的开发者账号
5. Interface: SwiftUI
6. Language: Swift
7. ✓ Include Tests
```

### 1.2 添加依赖

**Package.swift 或 SPM:**
```swift
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.0.0")
]
```

### 1.3 项目结构

```
BattleLM/
├── BattleLM.xcodeproj
├── BattleLM/
│   ├── App/
│   │   ├── BattleLMApp.swift          # App 入口
│   │   └── AppState.swift             # 全局状态
│   │
│   ├── Views/
│   │   ├── MainView.swift             # 主界面
│   │   ├── Sidebar/
│   │   │   ├── SidebarView.swift      # 侧边栏
│   │   │   ├── AIListView.swift       # AI 列表
│   │   │   └── GroupChatListView.swift # 群聊列表
│   │   ├── Chat/
│   │   │   ├── ChatView.swift         # 群聊主视图
│   │   │   ├── ChatHeaderView.swift   # 顶栏
│   │   │   ├── MessageListView.swift  # 消息列表
│   │   │   ├── MessageBubbleView.swift # 消息气泡
│   │   │   └── MessageInputView.swift  # 输入框
│   │   ├── Terminal/
│   │   │   ├── TerminalPanelView.swift # 终端区域
│   │   │   └── TerminalCardView.swift  # 单个终端卡片
│   │   └── Settings/
│   │       └── SettingsView.swift
│   │
│   ├── ViewModels/
│   │   ├── AppViewModel.swift
│   │   ├── ChatViewModel.swift
│   │   └── TerminalViewModel.swift
│   │
│   ├── Models/
│   │   ├── AIInstance.swift
│   │   ├── GroupChat.swift
│   │   ├── Message.swift
│   │   └── Enums.swift
│   │
│   ├── Services/
│   │   ├── SessionManager.swift       # tmux 会话管理
│   │   ├── MessageRouter.swift        # 消息路由
│   │   ├── ModeController.swift       # 模式控制
│   │   ├── EliminationEngine.swift    # 淘汰算法
│   │   └── DependencyChecker.swift    # 依赖检查
│   │
│   ├── Adapters/
│   │   ├── AIAdapterProtocol.swift
│   │   ├── ClaudeAdapter.swift
│   │   ├── GeminiAdapter.swift
│   │   └── CodexAdapter.swift
│   │
│   └── Resources/
│       └── Assets.xcassets
│
└── BattleLMTests/
```

---

## Phase 2: UI 界面开发 (第 2-3 周)

### 2.1 主界面框架

```swift
// MainView.swift
import SwiftUI

struct MainView: View {
    @StateObject private var appState = AppState()
    @State private var selectedChat: GroupChat?
    @State private var showTerminals = true
    
    var body: some View {
        NavigationSplitView {
            // 侧边栏
            SidebarView(selectedChat: $selectedChat)
                .frame(minWidth: 200, maxWidth: 250)
        } detail: {
            // 主内容区
            HStack(spacing: 0) {
                // 群聊区域
                if let chat = selectedChat {
                    ChatView(chat: chat)
                        .frame(minWidth: 400)
                } else {
                    EmptyStateView()
                }
                
                // AI 终端区域
                if showTerminals {
                    Divider()
                    TerminalPanelView()
                        .frame(width: 350)
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        .environmentObject(appState)
    }
}
```

### 2.2 消息气泡

```swift
// MessageBubbleView.swift
struct MessageBubbleView: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if message.senderType != .user {
                AvatarView(senderId: message.senderId)
            }
            
            VStack(alignment: message.senderType == .user ? .trailing : .leading) {
                if message.senderType != .user {
                    Text(message.senderName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Text(message.content)
                    .padding(12)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .cornerRadius(16)
            }
            
            if message.senderType == .user {
                Spacer()
            }
        }
        .padding(.horizontal)
    }
    
    var bubbleColor: Color {
        switch message.senderType {
        case .user: return .accentColor
        case .ai: return Color(.windowBackgroundColor)
        case .system: return .clear
        }
    }
}
```

### 2.3 终端面板

```swift
// TerminalPanelView.swift
import SwiftUI
import SwiftTerm

struct TerminalPanelView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("AI Workspaces")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
            // 终端列表
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(appState.aiInstances) { ai in
                        TerminalCardView(ai: ai)
                    }
                }
                .padding()
            }
        }
    }
}

struct TerminalCardView: View {
    let ai: AIInstance
    @State private var terminalView: LocalProcessTerminalView?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack {
                Circle()
                    .fill(ai.isEliminated ? .gray : .green)
                    .frame(width: 8, height: 8)
                Text("\(ai.name) Terminal")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if ai.isEliminated {
                    Text("ELIMINATED")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            
            // 终端视图
            SwiftTermView(ai: ai)
                .frame(height: 150)
                .opacity(ai.isEliminated ? 0.5 : 1.0)
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
        )
    }
}
```

---

## Phase 3: 核心服务层 (第 4-5 周)

### 3.1 Session Manager

```swift
// SessionManager.swift
import Foundation

class SessionManager: ObservableObject {
    static let shared = SessionManager()
    
    @Published var sessions: [UUID: TerminalSession] = [:]
    
    func createSession(for ai: AIInstance) async throws -> TerminalSession {
        let sessionName = "battlelm-\(ai.id.uuidString.prefix(8))"
        
        // 创建 tmux 会话
        try await runCommand("tmux", args: ["new-session", "-d", "-s", sessionName])
        
        // 启动 AI CLI
        try await runCommand("tmux", args: [
            "send-keys", "-t", sessionName, ai.type.cliCommand, "Enter"
        ])
        
        let session = TerminalSession(
            id: ai.id,
            name: sessionName,
            aiType: ai.type
        )
        
        sessions[ai.id] = session
        return session
    }
    
    func sendMessage(_ message: String, to ai: AIInstance) async throws {
        guard let session = sessions[ai.id] else {
            throw SessionError.notFound
        }
        
        try await runCommand("tmux", args: [
            "send-keys", "-t", session.name, message, "Enter"
        ])
    }
    
    func captureOutput(from ai: AIInstance) async throws -> String {
        guard let session = sessions[ai.id] else {
            throw SessionError.notFound
        }
        
        let result = try await runCommand("tmux", args: [
            "capture-pane", "-t", session.name, "-p", "-S", "-100"
        ])
        
        return result.stdout
    }
}
```

### 3.2 淘汰算法 (改进版：数值评分)

```swift
// EliminationEngine.swift
class EliminationEngine {
    static let shared = EliminationEngine()
    
    var eliminationThreshold: Double = 0.3
    
    struct AIEvaluation: Codable {
        let targetId: UUID
        let score: Int        // 0-10
        let pros: String
        let cons: String
    }
    
    /// 让 AI 评价另一个 AI 的输出
    func requestEvaluation(from evaluator: AIInstance,
                           of targetOutput: String,
                           targetAI: AIInstance) async throws -> AIEvaluation {
        let prompt = """
        请评价以下 AI (\(targetAI.name)) 的分析结果，并给出评分。
        
        分析内容：
        "\(targetOutput)"
        
        请用以下 JSON 格式返回（只返回 JSON，不要其他内容）：
        {
            "score": 7,
            "pros": "优点描述",
            "cons": "缺点描述"
        }
        """
        
        let response = try await SessionManager.shared.sendAndWait(prompt, to: evaluator)
        
        // 解析 JSON
        guard let data = response.data(using: .utf8),
              let json = try? JSONDecoder().decode(AIEvaluation.self, from: data) else {
            throw EvaluationError.parseError
        }
        
        return AIEvaluation(
            targetId: targetAI.id,
            score: json.score,
            pros: json.pros,
            cons: json.cons
        )
    }
    
    /// 计算应该淘汰的 AI
    func calculateEliminations(evaluations: [UUID: [AIEvaluation]]) -> [UUID] {
        var avgScores: [UUID: Double] = [:]
        
        for (aiId, evals) in evaluations {
            let scores = evals.map { Double($0.score) }
            avgScores[aiId] = scores.reduce(0, +) / Double(scores.count)
        }
        
        let sorted = avgScores.sorted { $0.value < $1.value }
        let eliminateCount = Int(Double(sorted.count) * eliminationThreshold)
        
        return sorted.prefix(eliminateCount).map { $0.key }
    }
}
```

---

## Phase 4: 依赖检查与启动流程 (第 6 周)

### 4.1 依赖检查器

```swift
// DependencyChecker.swift
struct DependencyChecker {
    
    struct Dependency {
        let name: String
        let command: String
        let installHint: String
    }
    
    static let required: [Dependency] = [
        Dependency(
            name: "tmux",
            command: "which tmux",
            installHint: "brew install tmux"
        )
    ]
    
    static let aiCLIs: [AIType: Dependency] = [
        .claude: Dependency(
            name: "Claude CLI",
            command: "which claude",
            installHint: "npm install -g @anthropic-ai/claude-cli"
        ),
        .gemini: Dependency(
            name: "Gemini CLI",
            command: "which gemini",
            installHint: "brew install gemini-cli"
        ),
        .codex: Dependency(
            name: "Codex CLI",
            command: "which codex",
            installHint: "npm install -g @openai/codex-cli"
        )
    ]
    
    static func checkAll() async -> [Dependency: Bool] {
        var results: [Dependency: Bool] = [:]
        
        for dep in required {
            results[dep] = await check(dep)
        }
        
        return results
    }
    
    static func check(_ dep: Dependency) async -> Bool {
        let result = try? await Process.run(dep.command)
        return result?.exitCode == 0
    }
}
```

### 4.2 App 启动流程

```swift
// BattleLMApp.swift
@main
struct BattleLMApp: App {
    @StateObject private var appState = AppState()
    @State private var showOnboarding = false
    @State private var missingDeps: [DependencyChecker.Dependency] = []
    
    var body: some Scene {
        WindowGroup {
            if missingDeps.isEmpty {
                MainView()
                    .environmentObject(appState)
            } else {
                OnboardingView(missingDeps: missingDeps)
            }
        }
        .commands {
            SidebarCommands()
        }
    }
    
    init() {
        Task {
            let results = await DependencyChecker.checkAll()
            missingDeps = results.filter { !$0.value }.map { $0.key }
        }
    }
}
```

---

## Phase 5: 测试与发布 (第 7-8 周)

### 5.1 测试计划

| 测试类型 | 范围 | 方法 |
|---------|------|------|
| 单元测试 | Models, EliminationEngine | XCTest |
| 集成测试 | SessionManager, MessageRouter | XCTest + Mock |
| UI 测试 | 主要用户流程 | XCUITest |
| 手动测试 | 完整讨论模式流程 | 开发者手动 |

### 5.2 发布清单

- [ ] App Icon 设计 (1024x1024)
- [ ] 截图准备 (5 张)
- [ ] App Store 描述文案
- [ ] 隐私政策 URL
- [ ] 支持 URL
- [ ] 提交审核

---

## 时间线总结

| 周 | 阶段 | 产出 |
|----|------|------|
| 0 | Spike 验证 | SwiftTerm + 响应检测确认可行 |
| 1 | 项目初始化 | Xcode 项目 + 基础架构 |
| 2-3 | UI 开发 | 完整界面 (侧边栏 + 群聊 + 终端) |
| 4-5 | 服务层 | SessionManager + 模式控制 + 淘汰 |
| 6 | 集成 | 依赖检查 + 启动流程 |
| 7-8 | 测试发布 | 测试 + App Store 提交 |

---

## 下一步行动

1. **完成 Spike 验证**（最关键）
2. **创建 Xcode 项目**
3. **集成 SwiftTerm**
4. **开始 UI 开发**
