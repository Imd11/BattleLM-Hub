// BattleLM/Models/TerminalTheme.swift
import SwiftUI

/// 终端主题定义
struct TerminalTheme: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let isDark: Bool              // 是否为暗色主题
    let backgroundColor: ColorHex
    let textColor: ColorHex
    let promptColor: ColorHex      // > $ % 提示符
    let responseColor: ColorHex    // AI 响应 ✦ •
    let borderColor: ColorHex      // 边框字符
    let errorColor: ColorHex       // 错误信息
    let warningColor: ColorHex     // 警告信息
    let successColor: ColorHex     // 成功信息
    let commentColor: ColorHex     // 次要文字
    
    var displayName: String { name }
}

/// 简单的十六进制颜色存储
struct ColorHex: Codable, Hashable {
    let hex: String
    
    init(_ hex: String) {
        self.hex = hex
    }
    
    var color: Color {
        Color(hex: hex)
    }
}

// Note: Color(hex:) extension is in AIInstance.swift

// MARK: - 预设主题
extension TerminalTheme {
    
    /// 所有可用主题
    static let allThemes: [TerminalTheme] = darkThemes + lightThemes
    
    /// 暗色主题
    static let darkThemes: [TerminalTheme] = [
        .oneDarkPro, .dracula, .nightOwl, .githubDark, .monokai,
        .catppuccinMocha, .tokyoNight, .ayuDark, .synthwave84,
        .solarizedDark, .gruvboxDark, .nord
    ]
    
    /// 亮色主题
    static let lightThemes: [TerminalTheme] = [
        .githubLight, .ayuLight, .solarizedLight, .atomOneLight
    ]
    
    /// 根据应用外观获取可用主题
    static func themes(for appearance: AppAppearance, colorScheme: ColorScheme?) -> [TerminalTheme] {
        switch appearance {
        case .dark:
            return darkThemes
        case .light:
            return lightThemes
        case .system:
            return colorScheme == .dark ? darkThemes : lightThemes
        }
    }
    
    /// 暗色默认
    static let defaultDark = oneDarkPro
    /// 亮色默认
    static let defaultLight = githubLight
    /// 默认主题
    static let `default` = oneDarkPro
    
    // MARK: - Dark Themes
    
    static let oneDarkPro = TerminalTheme(
        id: "one-dark-pro", name: "One Dark Pro", isDark: true,
        backgroundColor: ColorHex("#282C34"), textColor: ColorHex("#ABB2BF"),
        promptColor: ColorHex("#61AFEF"), responseColor: ColorHex("#98C379"),
        borderColor: ColorHex("#5C6370"), errorColor: ColorHex("#E06C75"),
        warningColor: ColorHex("#E5C07B"), successColor: ColorHex("#98C379"),
        commentColor: ColorHex("#5C6370")
    )
    
    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula", isDark: true,
        backgroundColor: ColorHex("#282A36"), textColor: ColorHex("#F8F8F2"),
        promptColor: ColorHex("#BD93F9"), responseColor: ColorHex("#50FA7B"),
        borderColor: ColorHex("#6272A4"), errorColor: ColorHex("#FF5555"),
        warningColor: ColorHex("#FFB86C"), successColor: ColorHex("#50FA7B"),
        commentColor: ColorHex("#6272A4")
    )
    
    static let nightOwl = TerminalTheme(
        id: "night-owl", name: "Night Owl", isDark: true,
        backgroundColor: ColorHex("#011627"), textColor: ColorHex("#D6DEEB"),
        promptColor: ColorHex("#7FDBCA"), responseColor: ColorHex("#ADDB67"),
        borderColor: ColorHex("#5F7E97"), errorColor: ColorHex("#EF5350"),
        warningColor: ColorHex("#FFCB6B"), successColor: ColorHex("#22DA6E"),
        commentColor: ColorHex("#637777")
    )
    
    static let githubDark = TerminalTheme(
        id: "github-dark", name: "GitHub Dark", isDark: true,
        backgroundColor: ColorHex("#0D1117"), textColor: ColorHex("#C9D1D9"),
        promptColor: ColorHex("#58A6FF"), responseColor: ColorHex("#7EE787"),
        borderColor: ColorHex("#30363D"), errorColor: ColorHex("#F85149"),
        warningColor: ColorHex("#D29922"), successColor: ColorHex("#3FB950"),
        commentColor: ColorHex("#8B949E")
    )
    
    static let monokai = TerminalTheme(
        id: "monokai", name: "Monokai", isDark: true,
        backgroundColor: ColorHex("#272822"), textColor: ColorHex("#F8F8F2"),
        promptColor: ColorHex("#66D9EF"), responseColor: ColorHex("#A6E22E"),
        borderColor: ColorHex("#75715E"), errorColor: ColorHex("#F92672"),
        warningColor: ColorHex("#E6DB74"), successColor: ColorHex("#A6E22E"),
        commentColor: ColorHex("#75715E")
    )
    
    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        backgroundColor: ColorHex("#1E1E2E"), textColor: ColorHex("#CDD6F4"),
        promptColor: ColorHex("#89DCEB"), responseColor: ColorHex("#A6E3A1"),
        borderColor: ColorHex("#45475A"), errorColor: ColorHex("#F38BA8"),
        warningColor: ColorHex("#FAB387"), successColor: ColorHex("#A6E3A1"),
        commentColor: ColorHex("#6C7086")
    )
    
    static let tokyoNight = TerminalTheme(
        id: "tokyo-night", name: "Tokyo Night", isDark: true,
        backgroundColor: ColorHex("#1A1B26"), textColor: ColorHex("#A9B1D6"),
        promptColor: ColorHex("#7AA2F7"), responseColor: ColorHex("#9ECE6A"),
        borderColor: ColorHex("#3B4261"), errorColor: ColorHex("#F7768E"),
        warningColor: ColorHex("#E0AF68"), successColor: ColorHex("#73DACA"),
        commentColor: ColorHex("#565F89")
    )
    
    static let ayuDark = TerminalTheme(
        id: "ayu-dark", name: "Ayu Dark", isDark: true,
        backgroundColor: ColorHex("#0A0E14"), textColor: ColorHex("#B3B1AD"),
        promptColor: ColorHex("#59C2FF"), responseColor: ColorHex("#AAD94C"),
        borderColor: ColorHex("#11151C"), errorColor: ColorHex("#D95757"),
        warningColor: ColorHex("#FFB454"), successColor: ColorHex("#7FD962"),
        commentColor: ColorHex("#626A73")
    )
    
    static let synthwave84 = TerminalTheme(
        id: "synthwave-84", name: "SynthWave '84", isDark: true,
        backgroundColor: ColorHex("#262335"), textColor: ColorHex("#BBBBBB"),
        promptColor: ColorHex("#FF7EDB"), responseColor: ColorHex("#72F1B8"),
        borderColor: ColorHex("#494366"), errorColor: ColorHex("#FE4450"),
        warningColor: ColorHex("#FEDE5D"), successColor: ColorHex("#72F1B8"),
        commentColor: ColorHex("#848BBD")
    )
    
    static let solarizedDark = TerminalTheme(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        backgroundColor: ColorHex("#002B36"), textColor: ColorHex("#839496"),
        promptColor: ColorHex("#268BD2"), responseColor: ColorHex("#859900"),
        borderColor: ColorHex("#073642"), errorColor: ColorHex("#DC322F"),
        warningColor: ColorHex("#B58900"), successColor: ColorHex("#2AA198"),
        commentColor: ColorHex("#586E75")
    )
    
    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark", name: "Gruvbox Dark", isDark: true,
        backgroundColor: ColorHex("#282828"), textColor: ColorHex("#EBDBB2"),
        promptColor: ColorHex("#83A598"), responseColor: ColorHex("#B8BB26"),
        borderColor: ColorHex("#3C3836"), errorColor: ColorHex("#FB4934"),
        warningColor: ColorHex("#FABD2F"), successColor: ColorHex("#B8BB26"),
        commentColor: ColorHex("#928374")
    )
    
    static let nord = TerminalTheme(
        id: "nord", name: "Nord", isDark: true,
        backgroundColor: ColorHex("#2E3440"), textColor: ColorHex("#D8DEE9"),
        promptColor: ColorHex("#88C0D0"), responseColor: ColorHex("#A3BE8C"),
        borderColor: ColorHex("#3B4252"), errorColor: ColorHex("#BF616A"),
        warningColor: ColorHex("#EBCB8B"), successColor: ColorHex("#A3BE8C"),
        commentColor: ColorHex("#4C566A")
    )
    
    // MARK: - Light Themes
    
    static let githubLight = TerminalTheme(
        id: "github-light", name: "GitHub Light", isDark: false,
        backgroundColor: ColorHex("#FFFFFF"), textColor: ColorHex("#24292F"),
        promptColor: ColorHex("#0550AE"), responseColor: ColorHex("#116329"),
        borderColor: ColorHex("#D0D7DE"), errorColor: ColorHex("#CF222E"),
        warningColor: ColorHex("#9A6700"), successColor: ColorHex("#1A7F37"),
        commentColor: ColorHex("#6E7781")
    )
    
    static let ayuLight = TerminalTheme(
        id: "ayu-light", name: "Ayu Light", isDark: false,
        backgroundColor: ColorHex("#FAFAFA"), textColor: ColorHex("#5C6166"),
        promptColor: ColorHex("#399EE6"), responseColor: ColorHex("#86B300"),
        borderColor: ColorHex("#E7E8E9"), errorColor: ColorHex("#F07171"),
        warningColor: ColorHex("#FA8D3E"), successColor: ColorHex("#4CBF99"),
        commentColor: ColorHex("#ABB0B6")
    )
    
    static let solarizedLight = TerminalTheme(
        id: "solarized-light", name: "Solarized Light", isDark: false,
        backgroundColor: ColorHex("#FDF6E3"), textColor: ColorHex("#657B83"),
        promptColor: ColorHex("#268BD2"), responseColor: ColorHex("#859900"),
        borderColor: ColorHex("#EEE8D5"), errorColor: ColorHex("#DC322F"),
        warningColor: ColorHex("#B58900"), successColor: ColorHex("#2AA198"),
        commentColor: ColorHex("#93A1A1")
    )
    
    static let atomOneLight = TerminalTheme(
        id: "atom-one-light", name: "Atom One Light", isDark: false,
        backgroundColor: ColorHex("#FAFAFA"), textColor: ColorHex("#383A42"),
        promptColor: ColorHex("#4078F2"), responseColor: ColorHex("#50A14F"),
        borderColor: ColorHex("#E5E5E6"), errorColor: ColorHex("#E45649"),
        warningColor: ColorHex("#C18401"), successColor: ColorHex("#50A14F"),
        commentColor: ColorHex("#A0A1A7")
    )
}
