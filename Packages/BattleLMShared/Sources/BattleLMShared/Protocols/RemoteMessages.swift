import Foundation

// MARK: - Event Stream (Mac → iOS)

/// 远程事件封装（Mac 维护递增 seq）
public struct RemoteEvent: Codable {
    public let type: String
    public let seq: Int
    public let payloadJSON: String
    public let timestamp: Date
    
    public init(type: String, seq: Int, payloadJSON: String) {
        self.type = type
        self.seq = seq
        self.payloadJSON = payloadJSON
        self.timestamp = Date()
    }
}

// MARK: - Payload Types

/// 发送消息 (iOS → Mac)
public struct SendMessagePayload: Codable {
    public let type: String
    public let aiId: UUID
    public let text: String
    
    public init(aiId: UUID, text: String) {
        self.type = "sendMessage"
        self.aiId = aiId
        self.text = text
    }
}

/// AI 回复 (Mac → iOS)
public struct AIResponsePayload: Codable {
    public let aiId: UUID
    public let message: MessageDTO
    public let isStreaming: Bool
    
    public init(aiId: UUID, message: MessageDTO, isStreaming: Bool) {
        self.aiId = aiId
        self.message = message
        self.isStreaming = isStreaming
    }
}

/// 终端选择提示 (Mac → iOS)
public struct TerminalPromptPayload: Codable {
    public let aiId: UUID
    public let title: String
    public let body: String?
    public let hint: String?
    public let options: [PromptOption]
    
    public struct PromptOption: Codable {
        public let number: Int
        public let label: String
        
        public init(number: Int, label: String) {
            self.number = number
            self.label = label
        }
    }
    
    public init(aiId: UUID, title: String, body: String?, hint: String?, options: [PromptOption]) {
        self.aiId = aiId
        self.title = title
        self.body = body
        self.hint = hint
        self.options = options
    }
}

/// 终端选择 (iOS → Mac)
public struct TerminalChoicePayload: Codable {
    public let type: String
    public let aiId: UUID
    public let choice: Int
    
    public init(aiId: UUID, choice: Int) {
        self.type = "terminalChoice"
        self.aiId = aiId
        self.choice = choice
    }
}

/// 同步请求 (iOS → Mac)
public struct SyncRequestPayload: Codable {
    public let type: String
    public let lastSeq: Int
    
    public init(lastSeq: Int) {
        self.type = "syncRequest"
        self.lastSeq = lastSeq
    }
}

/// AI 状态变更 (Mac → iOS)
public struct AIStatusPayload: Codable {
    public let aiId: UUID
    public let name: String
    public let provider: String?
    public let isRunning: Bool
    public let workingDirectory: String?
    
    public init(aiId: UUID, name: String, provider: String? = nil, isRunning: Bool, workingDirectory: String?) {
        self.aiId = aiId
        self.name = name
        self.provider = provider
        self.isRunning = isRunning
        self.workingDirectory = workingDirectory
    }
}

// MARK: - Group Chats

/// 创建群聊 (iOS → Mac)
public struct CreateGroupChatPayload: Codable {
    public let type: String
    public let name: String
    public let memberIds: [UUID]

    public init(name: String, memberIds: [UUID]) {
        self.type = "createGroupChat"
        self.name = name
        self.memberIds = memberIds
    }
}

/// 发送群聊消息 (iOS → Mac)
public struct SendGroupMessagePayload: Codable {
    public let type: String
    public let chatId: UUID
    public let text: String

    public init(chatId: UUID, text: String) {
        self.type = "sendGroupMessage"
        self.chatId = chatId
        self.text = text
    }
}

/// 群聊 DTO（iOS 显示用）
public struct GroupChatDTO: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let memberIds: [UUID]
    public let mode: String
    public let isActive: Bool
    public let messages: [MessageDTO]

    public init(id: UUID, name: String, memberIds: [UUID], mode: String, isActive: Bool, messages: [MessageDTO]) {
        self.id = id
        self.name = name
        self.memberIds = memberIds
        self.mode = mode
        self.isActive = isActive
        self.messages = messages
    }
}

/// 群聊快照 (Mac → iOS)
public struct GroupChatsSnapshotPayload: Codable {
    public let chats: [GroupChatDTO]

    public init(chats: [GroupChatDTO]) {
        self.chats = chats
    }
}

/// 群聊错误 (Mac → iOS)
public struct GroupChatErrorPayload: Codable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}

// MARK: - Message DTO

/// 可序列化消息（跨平台传输用）
public struct MessageDTO: Codable, Identifiable {
    public let id: UUID
    public let senderId: UUID
    public let senderType: String
    public let senderName: String
    public let content: String
    public let timestamp: Date
    
    public init(id: UUID, senderId: UUID, senderType: String, senderName: String, content: String, timestamp: Date) {
        self.id = id
        self.senderId = senderId
        self.senderType = senderType
        self.senderName = senderName
        self.content = content
        self.timestamp = timestamp
    }
}

// MARK: - AI Info DTO

/// AI 信息（iOS 显示用）
public struct AIInfoDTO: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let provider: String
    public let isRunning: Bool
    public let workingDirectory: String?
    
    public init(id: UUID, name: String, provider: String, isRunning: Bool, workingDirectory: String?) {
        self.id = id
        self.name = name
        self.provider = provider
        self.isRunning = isRunning
        self.workingDirectory = workingDirectory
    }
}
