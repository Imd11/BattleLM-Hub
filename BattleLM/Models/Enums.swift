// BattleLM/Models/Enums.swift
import Foundation

/// AI 类型
enum AIType: String, Codable, CaseIterable, Identifiable {
    case claude = "claude"
    case gemini = "gemini"
    case codex = "codex"
    case qwen = "qwen"
    case kimi = "kimi"
    
    var id: String { rawValue }
    
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
