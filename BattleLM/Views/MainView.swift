// BattleLM/Views/MainView.swift
import SwiftUI
import Combine

/// 主视图 - 三栏布局
struct MainView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) var colorScheme
    @State private var terminalWidth: CGFloat = 550

    
    private let minTerminalWidth: CGFloat = 550
    private let maxTerminalWidth: CGFloat = 600
    
    var body: some View {
        NavigationSplitView {
            // 左侧边栏
            SidebarView()
                .frame(minWidth: 200, maxWidth: 280)
        } detail: {
            // 主内容区
            HStack(spacing: 0) {
                // 内容区域：根据选择显示不同视图
                if let ai = appState.selectedAI {
                    // 1:1 AI 对话 - 使用 id 确保切换时重建视图
                    AIChatView(ai: ai)
                        .id(ai.id)
                        .frame(minWidth: 400)
                } else if appState.selectedGroupChat != nil {
                    // 群聊
                    ChatView()
                        .frame(minWidth: 400)
                } else {
                    // 空状态
                    EmptyStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // AI 终端区域（仅在群聊或 1:1 时显示）
                if appState.showTerminalPanel && (appState.selectedAI != nil || appState.selectedGroupChat != nil) {
                    // 可拖动分割线
                    ResizableDivider(width: $terminalWidth, minWidth: minTerminalWidth, maxWidth: maxTerminalWidth)
                    
                    if let ai = appState.selectedAI {
                        // 单个 AI 终端 - 使用 id 确保切换时重建视图
                        SingleTerminalView(ai: ai)
                            .id(ai.id)
                            .frame(width: terminalWidth)
                    } else {
                        // 多 AI 终端
                        TerminalPanelView()
                            .frame(width: terminalWidth)
                    }
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 700)
        // 应用外观
        .preferredColorScheme(appState.appAppearance.colorScheme)
        .sheet(isPresented: $appState.showAddAISheet) {
            AddAISheet()
        }
        .sheet(isPresented: $appState.showCreateGroupSheet) {
            CreateGroupSheet()
        }
        .sheet(isPresented: $appState.showSettingsSheet) {
            SettingsSheet()
        }
        .sheet(isPresented: $appState.showPairingSheet) {
            PairingQRView()
        }
        .toolbar {
            // 终端面板切换按钮 - 窗口右上角
            ToolbarItem(placement: .primaryAction) {
                Spacer()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.showTerminalPanel.toggle()
                    }
                } label: {
                    Image(systemName: appState.showTerminalPanel ? "sidebar.trailing" : "sidebar.trailing")
                        .symbolVariant(appState.showTerminalPanel ? .none : .none)
                        .foregroundColor(appState.showTerminalPanel ? .accentColor : .secondary)
                }
                .help(appState.showTerminalPanel ? "Hide Terminal (⌘T)" : "Show Terminal (⌘T)")
            }
        }
        .onChange(of: colorScheme) { newScheme in
            // 当系统 colorScheme 变化时，同步更新终端主题（仅在"跟随系统"模式下）
            guard appState.appAppearance == .system else { return }
            let shouldUseDark = newScheme == .dark
            if appState.terminalTheme.isDark != shouldUseDark {
                appState.terminalTheme = shouldUseDark ? .defaultDark : .defaultLight
            }
        }
    }
}

/// 可拖动分割线
struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    
    @State private var isDragging = false
    
    var body: some View {
        Rectangle()
            .fill(isDragging ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: isDragging ? 3 : 1)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        // 向左拖动增加宽度，向右拖动减少宽度
                        let newWidth = width - value.translation.width
                        width = min(max(newWidth, minWidth), maxWidth)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}

/// 单个 AI 终端视图
struct SingleTerminalView: View {
    let ai: AIInstance
    @EnvironmentObject var appState: AppState
    @State private var terminalOutput: String = ""
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var isInteractiveMode: Bool = true  // 默认显示 Interactive 模式
    @State private var isConnected: Bool = false
    
    // 每秒刷新的定时器
    private let autoRefreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    private var theme: TerminalTheme {
        appState.terminalTheme
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题
            HStack {
                Circle()
                    .fill(ai.isActive ? .green : .gray)
                    .frame(width: 8, height: 8)
                
                AILogoView(aiType: ai.type, size: 14)
                Text("\(ai.name) Terminal")
                    .fontWeight(.medium)
                Spacer()
                
                // 模式切换按钮
                if ai.isActive {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isInteractiveMode.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isInteractiveMode ? "terminal.fill" : "doc.text")
                                .font(.caption)
                            Text(isInteractiveMode ? "Interactive" : "Snapshot")
                                .font(.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isInteractiveMode ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.2))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help(isInteractiveMode ? "Switch to Snapshot mode" : "Switch to Interactive mode")
                    
                    // 手动刷新按钮（仅 Snapshot 模式）
                    if !isInteractiveMode {
                        Button {
                            refreshOutput()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
            // 终端内容区域 - 根据模式显示不同视图
            if isInteractiveMode && ai.isActive {
                // Interactive 模式：xterm.js + PTY 真终端
                XtermTerminalView(
                    command: "/opt/homebrew/bin/tmux",
                    args: ["-L", "battlelm", "attach", "-t", ai.tmuxSession],
                    theme: appState.terminalTheme,
                    isConnected: $isConnected,
                    onExit: { _ in
                        // 退出时自动切回 Snapshot 模式
                        withAnimation {
                            isInteractiveMode = false
                        }
                    }
                )
            } else {
                // Snapshot 模式：截图式终端
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if ai.isActive {
                            ForEach(Array(terminalLines.enumerated()), id: \.offset) { _, line in
                                coloredTerminalLine(line)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("$ \(ai.type.cliCommand)")
                                .foregroundColor(theme.promptColor.color)
                            Text("⏸ Session inactive. Click Start to begin.")
                                .foregroundColor(theme.commentColor.color)
                        }
                    }
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .background(theme.backgroundColor.color)
            }
            
            // 输入框（仅 Snapshot 模式且活跃 AI 时显示）
            if ai.isActive && !isInteractiveMode {
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(theme.promptColor.color)
                    
                    TextField("Type your message or @path/to/file", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(theme.textColor.color)
                        .onSubmit {
                            sendInput()
                        }
                    
                    if isSending {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Button {
                            sendInput()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .disabled(inputText.isEmpty)
                    }
                }
                .padding(10)
                .background(theme.backgroundColor.color)
            }
        }
        .onAppear {
            refreshOutput()
        }
        .onReceive(autoRefreshTimer) { _ in
            // 每秒自动刷新（仅 Snapshot 模式）
            if !isInteractiveMode {
                refreshOutput()
            }
        }
        .onChange(of: ai.isActive) { isActive in
            if isActive {
                refreshOutput()
            } else {
                terminalOutput = ""
            }
        }
    }
    
    private func sendInput() {
        guard !inputText.isEmpty, ai.isActive else { return }
        
        let message = inputText
        inputText = ""
        isSending = true
        
        Task {
            do {
                try await SessionManager.shared.sendMessage(message, to: ai)
                await MainActor.run {
                    isSending = false
                    // 立即刷新输出
                    refreshOutput()
                }
            } catch {
                print("❌ Failed to send: \(error)")
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
    
    /// 终端输出按行分割
    private var terminalLines: [String] {
        if terminalOutput.isEmpty {
            return ["Loading..."]
        }
        return terminalOutput.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }
    
    /// 根据内容给终端行上色
    @ViewBuilder
    private func coloredTerminalLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        if trimmed.isEmpty {
            Text(" ")
                .foregroundColor(.clear)
        } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") || trimmed.hasPrefix("%") {
            // 命令提示符
            Text(line)
                .foregroundColor(theme.promptColor.color)
        } else if trimmed.hasPrefix("✦") || trimmed.hasPrefix("•") {
            // AI 响应
            Text(line)
                .foregroundColor(theme.responseColor.color)
        } else if trimmed.contains("───") || trimmed.contains("│") || trimmed.contains("┌") || trimmed.contains("└") || trimmed.contains("┐") || trimmed.contains("┘") {
            // 边框
            Text(line)
                .foregroundColor(theme.borderColor.color)
        } else if trimmed.hasPrefix("Error") || trimmed.hasPrefix("error:") || trimmed.hasPrefix("ERROR") {
            // 错误 - 只匹配明确的错误开头
            Text(line)
                .foregroundColor(theme.errorColor.color)
        } else if trimmed.contains("Welcome") || trimmed.contains("Tips") || trimmed.hasPrefix("Warning") {
            // 警告/欢迎信息
            Text(line)
                .foregroundColor(theme.warningColor.color)
        } else {
            // 默认文字颜色
            Text(line)
                .foregroundColor(theme.textColor.color)
        }
    }
    
    private func refreshOutput() {
        guard ai.isActive else { return }
        Task {
            do {
                let output = try await SessionManager.shared.captureOutput(from: ai, lines: 10000)
                await MainActor.run {
                    terminalOutput = output
                }
            } catch {
                // 忽略错误
            }
        }
    }
}


/// 空状态视图
struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            Image("BattleLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
            
            Text("Welcome to BattleLM")
                .font(.title)
                .fontWeight(.medium)
            
            Text("Add AI instances and create group chats to get started")
                .foregroundColor(.secondary)
            
            HStack(spacing: 16) {
                Button {
                    appState.showAddAISheet = true
                } label: {
                    Label("Add AI", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
                
                Button {
                    appState.showCreateGroupSheet = true
                } label: {
                    Label("Create Group", systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.bordered)
                .disabled(appState.aiInstances.isEmpty)
            }
        }
    }
}

#Preview {
    MainView()
        .environmentObject(AppState())
}
