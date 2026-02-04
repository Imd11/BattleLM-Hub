// BattleLM/Models/AIInstance.swift
import Foundation
import SwiftUI

/// AI 实例模型
struct AIInstance: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let type: AIType
    var name: String
    var workingDirectory: String   // 工作目录
    var tmuxSession: String
    var isActive: Bool
    var isEliminated: Bool
    var eliminationScore: Double
    var messages: [Message] = []   // 1:1 对话消息历史
    
    // 手动实现 Hashable，只基于 id
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // 手动实现 Equatable，只基于 id
    static func == (lhs: AIInstance, rhs: AIInstance) -> Bool {
        lhs.id == rhs.id
    }
    
    init(type: AIType, name: String? = nil, workingDirectory: String = "~") {
        self.id = UUID()
        self.type = type
        self.name = name ?? "\(type.displayName)"
        self.workingDirectory = workingDirectory
        self.tmuxSession = "battlelm-\(self.id.uuidString.prefix(8))"
        self.isActive = false
        self.isEliminated = false
        self.eliminationScore = 0
        self.messages = []
    }
    
    /// 获取 AI 的颜色
    var color: Color {
        Color(hex: type.color)
    }
    
    /// 获取简短的路径显示
    var shortPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if workingDirectory.hasPrefix(home) {
            return "~" + workingDirectory.dropFirst(home.count)
        }
        return workingDirectory
    }
}

// MARK: - Color Extension
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
