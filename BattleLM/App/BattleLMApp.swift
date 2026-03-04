// BattleLM/App/BattleLMApp.swift
import SwiftUI
import CoreText

/// 注册应用内嵌的自定义字体
private func registerCustomFonts() {
    let fontNames = ["Orbitron-VariableFont"]
    for fontName in fontNames {
        guard let url = Bundle.main.url(forResource: fontName, withExtension: "ttf") else {
            print("⚠️ Font not found in bundle: \(fontName).ttf")
            continue
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            print("⚠️ Failed to register font \(fontName): \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        } else {
            print("✅ Registered font: \(fontName)")
        }
    }
}

@main
struct BattleLMApp: App {
    @StateObject private var appState = AppState()
    
    init() {
        registerCustomFonts()
    }
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(appState)
                .task {
                    // 启动即预热 CLI 检测：避免 Add AI Sheet 交互卡顿
                    appState.startCLIDetection()
                    RemoteHostServer.shared.bind(appState: appState)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
            
            // 文件菜单 - 替换默认的 New 命令
            CommandGroup(replacing: .newItem) {
                Button("New AI Instance") {
                    appState.showAddAISheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button("New Group Chat") {
                    appState.showCreateGroupSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            
            // 设置
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appState.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}
