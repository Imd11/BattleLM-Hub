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
    @State private var isInputFocused: Bool = false
    
    private var canSend: Bool {
        !isLoading
        && !(isAwaitingTerminalChoice && !supportsHeadlessChat)
        && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentAI: AIInstance {
        appState.aiInstance(for: ai.id) ?? ai
    }

    private var supportsHeadlessChat: Bool {
        switch currentAI.type {
        case .claude, .codex, .gemini, .qwen:
            return true
        default:
            return false
        }
    }

    @State private var isStartHovered = false
    @State private var isAttachHovered = false
    @State private var isSendHovered = false
    @State private var isFileTreeHovered = false

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
                
                // 启动/停止按钮
                Button {
                    toggleSession()
                } label: {
                    Image(systemName: isSessionRunning ? "stop.circle" : "play.circle")
                        .font(.title2)
                        .padding(4)
                        .background(
                            Circle()
                                .fill(isStartHovered ? Color.primary.opacity(0.08) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { isStartHovered = $0 }
                .disabled(sessionManager.sessionStatus[ai.id] == .starting)
                .help(isSessionRunning ? "Stop AI" : "Start AI")
            }
            .padding()
            // 背景色统一由外层 VStack 控制
            
            Divider()
            
            // 消息列表
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                // 空状态
                                VStack(spacing: 20) {
                                    AILogoView(aiType: currentAI.type, size: 80)
                                        .opacity(0.5)
                                    
                                    Text("Start a conversation with \(currentAI.name)")
                                        .font(.title)
                                        .fontWeight(.medium)
                                    
                                    Text("Working directory: \(currentAI.workingDirectory)")
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: geometry.size.height)
                            } else {
                                ForEach(messages) { message in
                                    AIChatBubbleView(message: message, ai: currentAI, containerWidth: geometry.size.width)
                                        .id(message.id)
                                }

                                // AI 正在思考（在真正有文本输出前显示）
                                if isLoading && streamingMessageId == nil && !isAwaitingTerminalChoice {
                                    HStack(alignment: .center, spacing: 12) {
                                        Spacer()
                                            .frame(width: geometry.size.width * 0.15)

                                        AILogoView(aiType: currentAI.type, size: 28)

                                        ThinkingDotsView()

                                        Spacer()

                                        Spacer()
                                            .frame(width: geometry.size.width * 0.15)
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
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { _ in
                clearInputFocus()
            })

            // ⚡ Headless 模式下不显示终端确认卡片（没有 tmux 会话产生 prompt）
            if let prompt = terminalChoicePrompt, !supportsHeadlessChat {
                TerminalChoicePromptCard(
                    aiName: currentAI.name,
                    prompt: prompt,
                    isSubmitting: isSubmittingTerminalChoice,
                    onOpenTerminal: {
                        // Terminal panel removed — using headless bridge
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
            // 输入面板 — 两行布局，用 GeometryReader 匹配聊天气泡的左右边距
            GeometryReader { inputGeo in
                let sideInset = 16 + inputGeo.size.width * 0.15
                VStack(spacing: 0) {
                    // ── Row 1: 文本输入 ──
                    ChatTextField(
                        placeholder: "Ask \(currentAI.name) something...",
                        text: $inputText,
                        focusId: ai.id,
                        focusRequestId: $focusRequestId,
                        onCommit: {
                            sendMessage()
                        },
                        onFocusChange: { focused in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isInputFocused = focused
                            }
                        }
                    )
                    .frame(minHeight: 36)
                    .disabled(isLoading)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    
                    // ── Row 2: 工具栏 ──
                    HStack(spacing: 8) {
                        // 附件按钮
                        Button {
                            attachFile()
                        } label: {
                            Image(systemName: "paperclip")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .onHover { isAttachHovered = $0 }
                        .frame(width: 24, height: 24, alignment: .center)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isAttachHovered ? Color.primary.opacity(0.08) : Color.clear)
                        )
                        .help("Attach file path")
                        
                        // Qwen 固定使用默认模型，不显示模型选择器
                        if currentAI.type != .qwen {
                            ModelSelectorView(
                                aiType: currentAI.type,
                                aiId: ai.id
                            )
                        }
                        
                        Spacer()
                        
                        // 发送按钮
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(canSend ? Color(hex: "#A3390E") : Color.gray.opacity(0.4))
                                .scaleEffect(isSendHovered && canSend ? 1.1 : 1.0)
                                .animation(.easeInOut(duration: 0.12), value: isSendHovered)
                        }
                        .disabled(!canSend)
                        .buttonStyle(.plain)
                        .onHover { isSendHovered = $0 }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(.windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    isInputFocused ? Color.accentColor.opacity(0.6) : Color.gray.opacity(0.25),
                                    lineWidth: isInputFocused ? 1.5 : 1
                                )
                        )
                        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    requestInputFocus()
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.iBeam.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .padding(.horizontal, sideInset)
                .padding(.top, 6)
                .padding(.bottom, 16)
            }
            .frame(height: 96)  // 两行布局需要更高
            // 背景色统一由外层 VStack 控制
        }
        .background(Color(.windowBackgroundColor))
        .onAppear {
            // 兼容历史状态：若 Qwen 曾选过非默认模型，进入页面后回退到默认模型
            if currentAI.type == .qwen, currentAI.selectedModel != nil {
                appState.setSelectedModel(nil, for: ai.id)
            }
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
    
    private func clearInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    
    // /clear 已移至右键菜单或顶部栏
    
    private func attachFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files to reference"
        panel.prompt = "Attach"
        
        guard panel.runModal() == .OK else { return }
        
        let paths = panel.urls.map { $0.path }
        let separator = inputText.isEmpty || inputText.hasSuffix(" ") ? "" : " "
        inputText += separator + paths.joined(separator: " ")
        requestInputFocus()
    }
    
    private func sendMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isLoading, !trimmed.isEmpty else { return }

        // 若终端正在等待用户确认（信任/权限等），先让用户完成确认再发送（保留输入框内容）
        // ⚡ Headless JSON 流模式下，非 slash command 消息不依赖 tmux 提示
        let isTerminalCommand = trimmed.hasPrefix("/")
        let headlessBypass = supportsHeadlessChat && !isTerminalCommand
        guard !isAwaitingTerminalChoice || headlessBypass else { return }

        let question = trimmed

        isLoading = true
        streamingMessageId = nil
        
        Task {
            do {
                // 发送前确保会话已启动；否则 MessageRouter/SessionManager 会找不到 session
                let hasSession = await MainActor.run { sessionManager.activeSessions[currentAI.id] != nil }
                if !hasSession {
                    try await AIStreamEngineRouter.active.startSession(for: currentAI)
                    appState.setAIActive(true, for: currentAI.id)
                    appState.setTerminalInteractive(true, for: currentAI.id)
                }

                // 某些 CLI（尤其 Claude）会在启动/执行工具前弹出需要用户选择的提示；
                // 检测到后直接展示卡片，保留用户输入以便确认后继续发送。
                //
                // ⚡ Headless JSON 流模式下的聊天消息不走 tmux，
                // tmux 终端里的权限提示与聊天路径无关，跳过检测。
                let useHeadless = supportsHeadlessChat && !isTerminalCommand
                if !useHeadless {
                    if await sessionManager.checkAndUpdateTerminalChoicePrompt(for: currentAI) != nil {
                        await MainActor.run {
                            isLoading = false
                            streamingMessageId = nil
                        }
                        return
                    }
                }

                await MainActor.run {
                    let userMessage = Message(
                        senderId: UUID(),
                        senderType: .user,
                        senderName: "You",
                        content: question,
                        messageType: .question
                    )
                    appState.appendMessage(userMessage, to: currentAI.id)
                    pendingScrollToMessageId = userMessage.id
                    inputText = ""
                }

                // 终端控制指令（/status /model /stats ...）：
                // - 不进入“等待 AI 回复”的 streaming 状态机（否则容易长期转圈并触发 busy）
                // - 尝试把终端打印的结果回显到聊天区（尤其是 /status 这类状态面板）
                if isTerminalCommand {
                    try await sessionManager.sendTerminalCommand(question, to: currentAI)
                    let output = try await sessionManager.captureTerminalCommandOutput(for: currentAI, command: question)

                    await MainActor.run {
                        isLoading = false
                        streamingMessageId = nil

                        if let output, !output.isEmpty {
                            // 终端控制指令输出（例如 /status）来自“该 AI 的终端”，
                            // 在 1:1 聊天中希望显示 AI 头像而非居中系统提示。
                            let terminalPanelMessage = Message(
                                senderId: currentAI.id,
                                senderType: .ai,
                                senderName: currentAI.name,
                                content: output,
                                messageType: .system
                            )
                            appState.appendMessage(terminalPanelMessage, to: currentAI.id)
                        }
                    }
                    return
                }

                await MessageRouter.shared.sendWithStreaming(question, to: currentAI) { content, _, isComplete in
                    DispatchQueue.main.async {
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
                    try await AIStreamEngineRouter.active.stopSession(for: aiSnapshot)
                    appState.setAIActive(false, for: aiSnapshot.id)
                } else {
                    // 启动会话
                    try await AIStreamEngineRouter.active.startSession(for: aiSnapshot)
                    appState.setAIActive(true, for: aiSnapshot.id)
                    appState.setTerminalInteractive(true, for: aiSnapshot.id)
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
        containerWidth * 0.60
    }
    
    @ViewBuilder
    var body: some View {
        if message.senderType == .system {
            HStack {
                Spacer()
                Text(message.content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(10)
                    .frame(maxWidth: maxBubbleWidth, alignment: .center)
                Spacer()
            }
        } else if message.messageType == .system {
            // 来自 AI 的“终端面板输出”（例如 /status），需要显示 AI 头像并保持等宽排版。
            HStack(alignment: .top, spacing: 12) {
                Spacer()
                    .frame(width: containerWidth * 0.15)

                if let ai = ai {
                    AILogoView(aiType: ai.type, size: 28)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .background(Color.gray.opacity(0.12))
                        .foregroundColor(.primary)
                        .cornerRadius(12)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: maxBubbleWidth, alignment: .leading)

                Spacer()
                Spacer()
                    .frame(width: containerWidth * 0.15)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                // 左侧空白（10%）
                Spacer()
                    .frame(width: containerWidth * 0.15)
                
                // 用户消息：左边额外空白推向右边
                if isUser {
                    Spacer()
                }
                
                // AI 头像
                if !isUser, let ai = ai {
                    AILogoView(aiType: ai.type, size: 28)
                }
                
                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                    Text(Self.markdownText(message.content))
                        .textSelection(.enabled)
                        .padding(12)
                        .background(isUser ? Color.accentColor : Color.gray.opacity(0.12))
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
                    .frame(width: containerWidth * 0.15)
            }
        }
    }

    /// Markdown → AttributedString；解析失败时回退为纯文本
    static func markdownText(_ raw: String) -> AttributedString {
        if let md = try? AttributedString(markdown: raw,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        return AttributedString(raw)
    }
}

#Preview {
    AIChatView(ai: AIInstance(type: .claude, name: "Claude", workingDirectory: "/Users/yang/Projects"))
        .environmentObject(AppState())
        .frame(width: 600, height: 500)
}
