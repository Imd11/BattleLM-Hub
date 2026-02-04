// BattleLM/App/BattleLMApp.swift
import SwiftUI

@main
struct BattleLMApp: App {
    @StateObject private var appState = AppState()
    
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
            
            // 文件菜单
            CommandGroup(after: .newItem) {
                Button("New AI Instance") {
                    appState.showAddAISheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])
                
                Button("New Group Chat") {
                    appState.showCreateGroupSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            
            // 视图菜单 - 终端切换
            CommandGroup(after: .sidebar) {
                Button(appState.showTerminalPanel ? "Hide Terminal" : "Show Terminal") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showTerminalPanel.toggle()
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                
                Divider()
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
