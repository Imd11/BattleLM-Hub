// BattleLM/Views/Terminal/TerminalPanelView.swift
import SwiftUI
import Combine

/// AI 终端面板视图
struct TerminalPanelView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExpanded: Bool = true
    
    /// 当前群聊的成员 AI
    var memberAIs: [AIInstance] {
        guard let chat = appState.selectedGroupChat else { return [] }
        return appState.aiInstances.filter { chat.memberIds.contains($0.id) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
                Text("AI Workspaces")
                    .font(.headline)
                
                Spacer()
                
                
                Button {
                    withAnimation {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
            if isExpanded {
                // 终端列表 - 只显示群聊成员
                ScrollView {
                    VStack(spacing: 12) {
                        if memberAIs.isEmpty {
                            Text("No AI in this chat")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            ForEach(memberAIs) { ai in
                                TerminalCardView(ai: ai)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .background(Color(.textBackgroundColor).opacity(0.3))
    }
}

/// 邀请 AI 加入群聊的 Sheet
struct InviteAISheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss
    
    var availableAIs: [AIInstance] {
        guard let chat = appState.selectedGroupChat else { return [] }
        return appState.aiInstances.filter { !chat.memberIds.contains($0.id) }
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Invite AI to Chat")
                .font(.title2)
                .fontWeight(.bold)
            
            if availableAIs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.green)
                    Text("All AI are already in this chat!")
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    ForEach(availableAIs) { ai in
                        Button {
                            inviteAI(ai)
                        } label: {
                            HStack {
                                AILogoView(aiType: ai.type, size: 16)
                                Text(ai.name)
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundColor(.accentColor)
                            }
                            .padding(12)
                            .background(Color(.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Spacer()
            
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 350, height: 300)
    }
    
    private func inviteAI(_ ai: AIInstance) {
        guard let chatId = appState.selectedGroupChatId,
              let index = appState.groupChats.firstIndex(where: { $0.id == chatId }) else { return }
        
        appState.groupChats[index].memberIds.append(ai.id)
        
        // 添加系统消息
        let message = Message.systemMessage("🤖 \(ai.name) joined the chat")
        appState.groupChats[index].messages.append(message)
    }
}

/// 单个终端卡片视图
struct TerminalCardView: View {
    let ai: AIInstance
    @State private var terminalOutput: String = ""
    @State private var inputText: String = ""
    @State private var isSending: Bool = false
    @State private var isInteractiveMode: Bool = false  // 双模式切换
    @State private var isConnected: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Circle()
                    .fill(ai.isEliminated ? .gray : .green)
                    .frame(width: 8, height: 8)
                
                AILogoView(aiType: ai.type, size: 14)
                
                Text("\(ai.name) Terminal")
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                // 模式切换按钮
                if ai.isActive && !ai.isEliminated {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isInteractiveMode.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isInteractiveMode ? "terminal.fill" : "doc.text")
                                .font(.caption2)
                            Text(isInteractiveMode ? "Interactive" : "Snapshot")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isInteractiveMode ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.2))
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .help(isInteractiveMode ? "Switch to Snapshot mode" : "Switch to Interactive mode")
                }
                
                if ai.isEliminated {
                    Text("ELIMINATED")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.2))
                        .cornerRadius(4)
                }
            }
            .padding(8)
            .background(Color(.controlBackgroundColor))
            
            // 终端内容区域 - 根据模式显示不同视图
            if isInteractiveMode && ai.isActive && !ai.isEliminated {
                // Interactive 模式：真实终端
                InteractiveTerminalView(
                    ai: ai,
                    isConnected: $isConnected,
                    onConnectionFailed: {
                        // 连接失败时自动切回 Snapshot 模式
                        withAnimation {
                            isInteractiveMode = false
                        }
                    }
                )
                .frame(height: 160)
            } else {
                // Snapshot 模式：原有截图式
                TerminalContentView(ai: ai)
                    .frame(height: 120)
                    .opacity(ai.isEliminated ? 0.5 : 1.0)
            }
            
            // 输入框（仅在 Snapshot 模式且活跃 AI 时显示）
            if ai.isActive && !ai.isEliminated && !isInteractiveMode {
                Divider()
                
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    
                    TextField("Type your message or @path/to/file", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption2, design: .monospaced))
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
                .padding(8)
                .background(Color(.textBackgroundColor))
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ai.isEliminated ? Color.red.opacity(0.3) : Color.gray.opacity(0.3), lineWidth: 1)
        )
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
                }
            } catch {
                print("❌ Failed to send: \(error)")
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
}

/// 终端内容视图 - 实时显示 AI 终端输出
struct TerminalContentView: View {
    let ai: AIInstance
    @EnvironmentObject var appState: AppState
    @State private var terminalOutput: String = ""
    
    // 每秒刷新
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    private var theme: TerminalTheme {
        appState.terminalTheme
    }
    
    /// 终端行 - 保留全部行以支持滚动查看
    private var terminalLines: [String] {
        if terminalOutput.isEmpty {
            return ai.isActive ? ["Loading..."] : ["Session inactive"]
        }
        return terminalOutput.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(terminalLines.enumerated()), id: \.offset) { index, line in
                        coloredLine(line)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(index)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .onChange(of: terminalLines.count) { _ in
                // 新输出时自动滚动到底部
                if let lastIndex = terminalLines.indices.last {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }
        }
        .background(theme.backgroundColor.color)
        .onAppear {
            refreshOutput()
        }
        .onReceive(refreshTimer) { _ in
            refreshOutput()
        }
    }
    
    /// 根据内容着色
    @ViewBuilder
    private func coloredLine(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        
        if trimmed.isEmpty {
            Text(" ").foregroundColor(.clear)
        } else if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") || trimmed.hasPrefix("%") {
            Text(line).foregroundColor(theme.promptColor.color)
        } else if trimmed.hasPrefix("✦") || trimmed.hasPrefix("•") {
            Text(line).foregroundColor(theme.responseColor.color)
        } else if trimmed.contains("───") || trimmed.contains("│") {
            Text(line).foregroundColor(theme.borderColor.color)
        } else if trimmed.hasPrefix("Error") || trimmed.hasPrefix("error:") {
            Text(line).foregroundColor(theme.errorColor.color)
        } else {
            Text(line).foregroundColor(theme.textColor.color)
        }
    }
    
    private func refreshOutput() {
        guard ai.isActive else {
            terminalOutput = ""
            return
        }
        
        Task {
            do {
                // 捕获更多行以支持滚动查看
                let output = try await SessionManager.shared.captureOutput(from: ai, lines: 100)
                await MainActor.run {
                    terminalOutput = output
                }
            } catch {
                // 忽略错误
            }
        }
    }
}

#Preview {
    TerminalPanelView()
        .environmentObject(AppState())
        .frame(width: 320, height: 500)
}
