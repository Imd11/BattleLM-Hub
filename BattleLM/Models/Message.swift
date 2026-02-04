// BattleLM/Models/Message.swift
import Foundation

/// 用户对消息的反应
enum UserReaction: String, Codable {
    case like = "like"
    case dislike = "dislike"
    
    var emoji: String {
        switch self {
        case .like: return "👍"
        case .dislike: return "👎"
        }
    }
}

/// 消息模型
struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    let senderId: UUID
    let senderType: SenderType
    let senderName: String
    var content: String               // 改为 var 以支持流式更新
    let timestamp: Date
    let roundNumber: Int
    let messageType: MessageType
    var userReaction: UserReaction?   // 用户的反应
    var isStreaming: Bool = false     // 是否正在流式输出
    
    init(
        senderId: UUID,
        senderType: SenderType,
        senderName: String,
        content: String,
        roundNumber: Int = 0,
        messageType: MessageType = .question,
        userReaction: UserReaction? = nil
    ) {
        self.id = UUID()
        self.senderId = senderId
        self.senderType = senderType
        self.senderName = senderName
        self.content = content
        self.timestamp = Date()
        self.roundNumber = roundNumber
        self.messageType = messageType
        self.userReaction = userReaction
        self.isStreaming = false
    }
    
    /// 用于更新消息内容（保留原 ID 和时间戳）
    init(
        id: UUID,
        senderId: UUID,
        senderType: SenderType,
        senderName: String,
        content: String,
        timestamp: Date,
        roundNumber: Int = 0,
        messageType: MessageType = .question,
        userReaction: UserReaction? = nil
    ) {
        self.id = id
        self.senderId = senderId
        self.senderType = senderType
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
        self.roundNumber = roundNumber
        self.messageType = messageType
        self.userReaction = userReaction
    }
    
    /// 创建用户消息
    static func userMessage(_ content: String) -> Message {
        Message(
            senderId: UUID(), // 用户 ID 可以固定
            senderType: .user,
            senderName: "You",
            content: content,
            messageType: .question
        )
    }
    
    /// 创建系统消息
    static func systemMessage(_ content: String) -> Message {
        Message(
            senderId: UUID(),
            senderType: .system,
            senderName: "System",
            content: content,
            messageType: .system
        )
    }
}
