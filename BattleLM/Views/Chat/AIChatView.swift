// BattleLM/Views/Chat/AIChatView.swift
import SwiftUI

/// 1:1 AI 对话视图
struct AIChatView: View {
    @EnvironmentObject var appState: AppState
    let ai: AIInstance

    @StateObject private var sessionManager = SessionManager.shared
    
    @State private var inputText: String = ""
    @State private var isLoading: Bool = false
    @State private var streamingMessageId: UUID? = nil
    @State private var pendingScrollToMessageId: UUID? = nil
    @State private var focusRequestId: UUID? = nil
    @State private var isSubmittingTerminalChoice: Bool = false

    private var currentAI: AIInstance {
        appState.aiInstance(for: ai.id) ?? ai
    }

    private var isSessionRunning: Bool {
        sessionManager.sessionStatus[ai.id] == .running
    }

    private var terminalChoicePrompt: TerminalChoicePrompt? {
        sessionManager.terminalChoicePrompts[ai.id]
    }

    private var isAwaitingTerminalChoice: Bool {
        terminalChoicePrompt != nil
    }
    
    /// 从 AppState 获取当前 AI 的消息
    var messages: [Message] {
        appState.aiInstance(for: ai.id)?.messages ?? []
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            HStack {
                // AI 信息
                HStack(spacing: 12) {
                    Circle()
                        .fill(isSessionRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    
                    AILogoView(aiType: currentAI.type, size: 24)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentAI.name)
                            .font(.headline)
                        Text(currentAI.shortPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // 状态
                if isLoading || sessionManager.sessionStatus[ai.id] == .starting {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                // 启动/停止按钮
                Button {
                    toggleSession()
                } label: {
                    Image(systemName: isSessionRunning ? "stop.circle" : "play.circle")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(sessionManager.sessionStatus[ai.id] == .starting)
                .help(isSessionRunning ? "Stop AI" : "Start AI")
            }
            .padding()
            .background(Color(.windowBackgroundColor))
            
            Divider()
            
            // 消息列表
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                // 空状态
                                VStack(spacing: 16) {
                                    AILogoView(aiType: currentAI.type, size: 48)
                                        .opacity(0.5)
                                    
                                    Text("Start a conversation with \(currentAI.name)")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    
                                    Text("Working directory: \(currentAI.workingDirectory)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.top, 100)
                            } else {
                                ForEach(messages) { message in
                                    AIChatBubbleView(message: message, ai: currentAI, containerWidth: geometry.size.width)
                                        .id(message.id)
                                }

                                // AI 正在思考（在真正有文本输出前显示）
                                if isLoading && streamingMessageId == nil && !isAwaitingTerminalChoice {
                                    HStack(alignment: .center, spacing: 12) {
                                        Spacer()
                                            .frame(width: geometry.size.width * 0.10)

                                        AILogoView(aiType: currentAI.type, size: 28)

                                        ThinkingDotsView()

                                        Spacer()

                                        Spacer()
                                            .frame(width: geometry.size.width * 0.10)
                                    }
                                    .id("thinking-indicator")
                                }

                                // 为 AI 输出预留空间（类似 ChatGPT 的“下方留白”）
                                if isLoading {
                                    Color.clear
                                        .frame(height: max(220, geometry.size.height * 0.55))
                                        .accessibilityHidden(true)
                                }

                                // 便于滚动到底部
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _ in
                        // 发送后：只做一次“把用户消息顶到上方”的 reposition
                        if let target = pendingScrollToMessageId {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .top)
                            }
                            pendingScrollToMessageId = nil
                            return
                        }

                        // loading 期间不强制滚动：用户手动滚动时不拉回
                        guard !isLoading, let lastMessage = messages.last else { return }
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let prompt = terminalChoicePrompt {
                TerminalChoicePromptCard(
                    aiName: currentAI.name,
                    prompt: prompt,
                    isSubmitting: isSubmittingTerminalChoice,
                    onOpenTerminal: {
                        appState.showTerminalPanel = true
                    },
                    onSelect: { option in
                        guard !isSubmittingTerminalChoice else { return }
                        isSubmittingTerminalChoice = true
                        Task {
                            do {
                                try await sessionManager.submitTerminalChoice(option.number, for: currentAI)
                            } catch {
                                let errorMessage = Message.systemMessage("❌ Failed to respond: \(error.localizedDescription)")
                                appState.appendMessage(errorMessage, to: currentAI.id)
                            }
                            await MainActor.run {
                                isSubmittingTerminalChoice = false
                                requestInputFocus()
                            }
                        }
                    }
                )
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            
            Divider()
            
            // 输入区域
            HStack(spacing: 12) {
                ChatTextField(
                    placeholder: "Ask \(currentAI.name) something...",
                    text: $inputText,
                    focusId: ai.id,
                    focusRequestId: $focusRequestId,
                    onCommit: {
                        sendMessage()
                    }
                )
                // 允许在会话启动期间先输入；发送会自动启动会话
                .disabled(isLoading)
                
                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(isLoading || isAwaitingTerminalChoice || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
        .onAppear {
            requestInputFocus()
        }
    }

    private func requestInputFocus() {
        focusRequestId = ai.id
        // One-shot: clear so later requests re-trigger.
        DispatchQueue.main.async {
            if focusRequestId == ai.id {
                focusRequestId = nil
            }
        }
    }
    
    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading, !trimmed.isEmpty else { return }

        // 若终端正在等待用户确认（信任/权限等），先让用户完成确认再发送（保留输入框内容）
        guard !isAwaitingTerminalChoice else { return }

        let question = trimmed

        isLoading = true
        streamingMessageId = nil
        
        Task {
            do {
                // 发送前确保会话已启动；否则 MessageRouter/SessionManager 会找不到 session
                let hasSession = await MainActor.run { sessionManager.activeSessions[currentAI.id] != nil }
                if !hasSession {
                    try await sessionManager.startSession(for: currentAI)
                    appState.setAIActive(true, for: currentAI.id)
                }

                // 某些 CLI（尤其 Claude）会在启动/执行工具前弹出需要用户选择的提示；
                // 检测到后直接展示卡片，保留用户输入以便确认后继续发送。
                if await sessionManager.checkAndUpdateTerminalChoicePrompt(for: currentAI) != nil {
                    await MainActor.run {
                        isLoading = false
                        streamingMessageId = nil
                    }
                    return
                }

                await MainActor.run {
                    // 添加用户消息
                    let userMessage = Message(
                        senderId: UUID(),
                        senderType: .user,
                        senderName: "You",
                        content: question,
                        messageType: .question
                    )
                    appState.appendMessage(userMessage, to: currentAI.id)
                    pendingScrollToMessageId = userMessage.id

                    // 只有在确定可以发送时才清空输入框
                    inputText = ""
                }

                await MessageRouter.shared.sendWithStreaming(question, to: currentAI) { content, _, isComplete in
                    DispatchQueue.main.async {
                        // 只要第一次拿到非空内容，才创建 AI 气泡；在此之前只显示“三点跳动”
                        if streamingMessageId == nil && !content.isEmpty {
                            let aiMessage = Message(
                                senderId: currentAI.id,
                                senderType: .ai,
                                senderName: currentAI.name,
                                content: content,
                                messageType: .analysis
                            )
                            streamingMessageId = aiMessage.id
                            appState.appendMessage(aiMessage, to: currentAI.id)
                        } else if let messageId = streamingMessageId {
                            appState.updateMessage(messageId, content: content, aiId: currentAI.id)
                        }

                        if isComplete {
                            isLoading = false
                            streamingMessageId = nil
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    streamingMessageId = nil
                    let errorMessage = Message.systemMessage("❌ Failed to start \(currentAI.name): \(error.localizedDescription)")
                    appState.appendMessage(errorMessage, to: currentAI.id)
                }
            }
        }
    }
    
    /// 提取输出中的新增内容
    private func extractNewContent(before: String, after: String) -> String {
        let beforeLines = Set(before.split(separator: "\n").map { String($0) })
        let afterLines = after.split(separator: "\n").map { String($0) }
        
        // 找出新增的行
        var newLines: [String] = []
        for line in afterLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过空行、边框字符、命令提示符
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(">") || trimmed.hasPrefix("$") || trimmed.hasPrefix("%") { continue }
            if trimmed.contains("──") || trimmed.contains("│") { continue }
            
            // 检查是否是新行
            if !beforeLines.contains(line) {
                // AI 响应通常以特定字符开头
                if trimmed.hasPrefix("✦") || trimmed.hasPrefix("•") || 
                   trimmed.hasPrefix("I ") || trimmed.hasPrefix("The ") ||
                   trimmed.count > 20 {
                    newLines.append(trimmed)
                }
            }
        }
        
        return newLines.joined(separator: "\n")
    }
    
    private func toggleSession() {
        let aiSnapshot = currentAI

        Task {
            do {
                if isSessionRunning {
                    // 停止会话
                    try await sessionManager.stopSession(for: aiSnapshot)
                    appState.setAIActive(false, for: aiSnapshot.id)
                } else {
                    // 启动会话
                    try await sessionManager.startSession(for: aiSnapshot)
                    appState.setAIActive(true, for: aiSnapshot.id)
                    let systemMessage = Message.systemMessage("🟢 \(aiSnapshot.name) session started in \(aiSnapshot.shortPath)")
                    appState.appendMessage(systemMessage, to: aiSnapshot.id)
                }
            } catch {
                let errorMessage = Message.systemMessage("❌ Failed to toggle session: \(error.localizedDescription)")
                appState.appendMessage(errorMessage, to: aiSnapshot.id)
            }
        }
    }
}

/// 1:1 对话气泡视图
struct AIChatBubbleView: View {
    let message: Message
    let ai: AIInstance?
    let containerWidth: CGFloat
    
    var isUser: Bool {
        message.senderType == .user
    }
    
    var maxBubbleWidth: CGFloat {
        containerWidth * 0.7
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左侧空白（10%）
            Spacer()
                .frame(width: containerWidth * 0.10)
            
            // 用户消息：左边额外空白推向右边
            if isUser {
                Spacer()
            }
            
            // AI 头像
            if !isUser, let ai = ai {
                AILogoView(aiType: ai.type, size: 28)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .padding(12)
                    .background(isUser ? Color.accentColor : Color(.controlBackgroundColor))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(16)
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: maxBubbleWidth, alignment: isUser ? .trailing : .leading)
            
            // AI 消息：右边额外空白
            if !isUser {
                Spacer()
            }
            
            // 用户头像
            if isUser {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundColor(.white)
                    )
            }
            
            // 右侧空白（10%）
            Spacer()
                .frame(width: containerWidth * 0.10)
        }
    }
}

#Preview {
    AIChatView(ai: AIInstance(type: .claude, name: "Claude", workingDirectory: "/Users/demo/Projects"))
        .environmentObject(AppState())
        .frame(width: 600, height: 500)
}
