// BattleLM/Models/GroupChat.swift
import Foundation

/// 群聊模型
struct GroupChat: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var memberIds: [UUID]
    var messages: [Message]
    var mode: ChatMode
    var eliminatedIds: [UUID]
    var currentRound: Int
    var isActive: Bool
    
    init(name: String, memberIds: [UUID] = []) {
        self.id = UUID()
        self.name = name
        self.memberIds = memberIds
        self.messages = []
        self.mode = .discussion
        self.eliminatedIds = []
        self.currentRound = 0
        self.isActive = false
    }
    
    /// 获取活跃的成员（未淘汰的）
    var activeMemberIds: [UUID] {
        memberIds.filter { !eliminatedIds.contains($0) }
    }
    
    /// Hashable 实现（排除 messages）
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: GroupChat, rhs: GroupChat) -> Bool {
        lhs.id == rhs.id
    }
}
