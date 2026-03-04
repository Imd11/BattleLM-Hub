// BattleLM/Models/Enums.swift
import Foundation

/// 推理深度（第二级选择）
enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case xhigh = "xhigh"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        }
    }
    
    var shortName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .xhigh: return "XHigh"
        }
    }
    
    var subtitle: String {
        switch self {
        case .low: return "Fast responses with lighter reasoning"
        case .medium: return "Balances speed and reasoning depth"
        case .high: return "Greater reasoning depth for complex problems"
        case .xhigh: return "Extra high reasoning depth for complex problems"
        }
    }
}

/// 模型选项
struct ModelOption: Identifiable {
    let id: String                           // 唯一 ID (e.g. "claude-sonnet-4-6:thinking")
    let displayName: String                  // 显示名称
    let subtitle: String                     // 描述
    var isDefault: Bool = false
    var reasoningEfforts: [ReasoningEffort] = []  // 空 = 无第二级选择
    var defaultEffort: ReasoningEffort? = nil     // 默认推理深度
    var enableThinking: Bool = false              // 是否开启 thinking 模式
    
    /// 是否有第二级选择
    var hasReasoningEffort: Bool { !reasoningEfforts.isEmpty }
    
    /// 实际传给 API 的模型 ID（去掉 (thinking) 后缀）
    var actualModelId: String {
        id.replacingOccurrences(of: "(thinking)", with: "")
    }
}

/// AI 类型
enum AIType: String, Codable, CaseIterable, Identifiable {
    case claude = "claude"
    case gemini = "gemini"
    case codex = "codex"
    case qwen = "qwen"
    case kimi = "kimi"
    
    var id: String { rawValue }
    
    /// 用户可见的 AI 类型（排除未就绪的）
    static var userVisibleCases: [AIType] {
        allCases.filter { $0 != .kimi }
    }    
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .codex: return "Codex"
        case .qwen: return "Qwen"
        case .kimi: return "Kimi"
        }
    }
    
    var cliCommand: String {
        switch self {
        case .claude: return "claude"
        case .gemini: return "gemini"
        case .codex: return "codex"
        case .qwen: return "qwen"
        case .kimi: return "kimi"
        }
    }
    
    /// SF Symbol 图标名（备用）
    var iconName: String {
        switch self {
        case .claude: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .qwen: return "wand.and.stars"
        case .kimi: return "moon.stars"
        }
    }
    
    /// 自定义 Logo 图片名
    var logoImageName: String {
        switch self {
        case .claude: return "ClaudeLogo"
        case .gemini: return "GeminiLogo"
        case .codex: return "OpenAILogo"
        case .qwen: return "qwen"
        case .kimi: return "KimiLogo"
        }
    }
    
    var color: String {
        switch self {
        case .claude: return "#E07850" // Orange (Claude's actual color)
        case .gemini: return "#4285F4" // Google Blue
        case .codex: return "#00A67E" // OpenAI Green
        case .qwen: return "#6366F1" // Indigo (Qwen's color)
        case .kimi: return "#00D4AA" // Kimi Cyan/Teal
        }
    }

    /// 当前 AI 类型可用的模型列表
    var availableModels: [ModelOption] {
        let fullEfforts: [ReasoningEffort] = [.low, .medium, .high, .xhigh]
        let miniEfforts: [ReasoningEffort] = [.medium, .high]
        
        switch self {
        case .codex:
            return [
                ModelOption(id: "gpt-5.3-codex", displayName: "gpt-5.3-codex",
                           subtitle: "Latest frontier agentic coding model",
                           isDefault: true,
                           reasoningEfforts: fullEfforts, defaultEffort: .medium),
                ModelOption(id: "gpt-5.2-codex", displayName: "gpt-5.2-codex",
                           subtitle: "Frontier agentic coding model",
                           reasoningEfforts: fullEfforts, defaultEffort: .medium),
                ModelOption(id: "gpt-5.1-codex-max", displayName: "gpt-5.1-codex-max",
                           subtitle: "Codex-optimized flagship for deep and fast reasoning",
                           reasoningEfforts: fullEfforts, defaultEffort: .medium),
                ModelOption(id: "gpt-5.2", displayName: "gpt-5.2",
                           subtitle: "Latest frontier model with improvements across knowledge, reasoning and coding",
                           reasoningEfforts: fullEfforts, defaultEffort: .medium),
                ModelOption(id: "gpt-5.1-codex-mini", displayName: "gpt-5.1-codex-mini",
                           subtitle: "Optimized for codex. Cheaper, faster, but less capable",
                           reasoningEfforts: miniEfforts, defaultEffort: .medium),
            ]
        case .claude:
            let claudeEfforts: [ReasoningEffort] = [.low, .medium, .high]
            return [
                ModelOption(id: "claude-sonnet-4-6", displayName: "claude-sonnet-4-6",
                           subtitle: "Latest fast and capable", isDefault: true),
                ModelOption(id: "claude-sonnet-4-6(thinking)", displayName: "claude-sonnet-4-6(thinking)",
                           subtitle: "Sonnet 4.6 with extended thinking",
                           reasoningEfforts: claudeEfforts, defaultEffort: .high,
                           enableThinking: true),
                ModelOption(id: "claude-opus-4-6(thinking)", displayName: "claude-opus-4-6(thinking)",
                           subtitle: "Most powerful Claude model with thinking",
                           enableThinking: true),

                ModelOption(id: "claude-haiku-4-5-20251001", displayName: "claude-haiku-4-5-20251001",
                           subtitle: "Fast and affordable"),
            ]
        case .qwen:
            return [
                ModelOption(id: "coder-model", displayName: "coder-model",
                           subtitle: "Coding agent model", isDefault: true),
                ModelOption(id: "vision-model", displayName: "vision-model",
                           subtitle: "Vision-capable model"),
            ]
        case .gemini:
            return [
                ModelOption(id: "gemini-3-pro-preview", displayName: "gemini-3-pro-preview",
                           subtitle: "Most intelligent model, advanced reasoning", isDefault: true),
                ModelOption(id: "gemini-3-flash-preview", displayName: "gemini-3-flash-preview",
                           subtitle: "Pro-level intelligence at Flash speed"),
                ModelOption(id: "gemini-2.5-pro", displayName: "gemini-2.5-pro",
                           subtitle: "Previous generation pro model"),
                ModelOption(id: "gemini-2.5-flash", displayName: "gemini-2.5-flash",
                           subtitle: "Previous generation flash model"),
            ]
        case .kimi:
            return []
        }
    }

    /// 默认模型 ID
    var defaultModelId: String {
        availableModels.first(where: \.isDefault)?.id ?? availableModels.first?.id ?? ""
    }
}

/// 发送者类型
enum SenderType: String, Codable {
    case user
    case ai
    case system
}

/// 消息类型
enum MessageType: String, Codable {
    case question      // 用户问题
    case analysis      // AI 问题分析
    case evaluation    // AI 评价
    case system        // 系统消息
}

/// 聊天模式
enum ChatMode: String, Codable, CaseIterable, Identifiable {
    case discussion    // 讨论模式：AI 互相交流评价
    case qna           // Q&A 模式：AI 独立回答，不互相交流
    case solo          // Solo 模式：指定单个 AI 执行
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .discussion: return "Debate"
        case .qna: return "Poll"
        case .solo: return "Solo"
        }
    }
    
    var description: String {
        switch self {
        case .discussion: return "All AIs debate in 3 rounds"
        case .qna: return "Each AI answers once, separately"
        case .solo: return "Send to one AI only"
        }
    }
    
    var iconName: String {
        switch self {
        case .discussion: return "bubble.left.and.bubble.right"
        case .qna: return "questionmark.bubble"
        case .solo: return "person.fill"
        }
    }
    
    /// 最大回合数
    var maxRounds: Int {
        switch self {
        case .discussion: return 3  // Round 1: 分析, Round 2: 评价, Round 3: 修正
        case .qna: return 1         // 只有 1 轮，每个 AI 独立回答
        case .solo: return 1        // 只有 1 轮，单个 AI 执行
        }
    }
}
