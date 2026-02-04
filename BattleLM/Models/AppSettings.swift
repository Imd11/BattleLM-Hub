// BattleLM/Models/AppSettings.swift
import SwiftUI

/// 应用外观模式
enum AppAppearance: String, CaseIterable, Identifiable, Codable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    
    var iconName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 强调色
enum AccentColorOption: String, CaseIterable, Identifiable, Codable {
    case blue = "blue"
    case purple = "purple"
    case green = "green"
    case orange = "orange"
    case pink = "pink"
    case red = "red"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .red: return "Red"
        }
    }
    
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .red: return .red
        }
    }
}

/// 终端位置
enum TerminalPosition: String, CaseIterable, Identifiable, Codable {
    case right = "right"
    case bottom = "bottom"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .right: return "Right"
        case .bottom: return "Bottom"
        }
    }
    
    var iconName: String {
        switch self {
        case .right: return "sidebar.right"
        case .bottom: return "sidebar.squares.trailing"
        }
    }
}

/// 字体大小
enum FontSizeOption: String, CaseIterable, Identifiable, Codable {
    case small = "small"
    case medium = "medium"
    case large = "large"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
    
    var chatFont: Font {
        switch self {
        case .small: return .callout
        case .medium: return .body
        case .large: return .title3
        }
    }
    
    var terminalFont: Font {
        switch self {
        case .small: return .system(.caption2, design: .monospaced)
        case .medium: return .system(.caption, design: .monospaced)
        case .large: return .system(.body, design: .monospaced)
        }
    }
}

/// 时间戳格式
enum TimestampFormat: String, CaseIterable, Identifiable, Codable {
    case hidden = "hidden"
    case time = "time"
    case full = "full"
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .hidden: return "Hidden"
        case .time: return "Time Only (2:30 PM)"
        case .full: return "Full (Jan 28, 2:30 PM)"
        }
    }
}
