// BattleLM/Services/SessionManager.swift
import Foundation
import Combine

/// tmux 会话管理器
class SessionManager: ObservableObject {
    static let shared = SessionManager()
    
    /// 活跃的会话 [AI ID: tmux session name]
    @Published var activeSessions: [UUID: String] = [:]
    
    /// 会话状态
    @Published var sessionStatus: [UUID: SessionStatus] = [:]

    /// 终端交互式选择提示（例如 Claude 的权限/信任确认）
    @Published var terminalChoicePrompts: [UUID: TerminalChoicePrompt] = [:]

    // Claude transcript 对齐：记录“本轮发送”的上下文，用于避免错位（上一轮回复被当成本轮）
    private struct ClaudePendingRequest {
        let transcriptURL: URL
        let afterUserUuid: String?
        let expectedUserText: String
        let minTimestamp: Date
    }

    private let transientState = TransientState()
    private let startSessionGate = StartSessionGate()
    private let terminalPromptMonitorState = TerminalPromptMonitorState()
    
    private init() {}

    private func broadcastToRemote(aiId: UUID, message: MessageDTO, isStreaming: Bool) {
        Task { @MainActor in
            let payload = AIResponsePayload(aiId: aiId, message: message, isStreaming: isStreaming)
            RemoteHostServer.shared.broadcast(type: "aiResponse", payload: payload)
        }
    }

    private actor TransientState {
        private var claudePendingRequests: [UUID: ClaudePendingRequest] = [:]
        private var pendingUserMessages: [UUID: String] = [:]

        func claudePendingRequest(for aiId: UUID) -> ClaudePendingRequest? {
            claudePendingRequests[aiId]
        }

        func setClaudePendingRequest(_ request: ClaudePendingRequest, for aiId: UUID) {
            claudePendingRequests[aiId] = request
        }

        func clearClaudePendingRequest(for aiId: UUID) {
            claudePendingRequests.removeValue(forKey: aiId)
        }

        func pendingUserMessage(for aiId: UUID) -> String? {
            pendingUserMessages[aiId]
        }

        func setPendingUserMessage(_ message: String, for aiId: UUID) {
            pendingUserMessages[aiId] = message
        }

        func clearPendingUserMessage(for aiId: UUID) {
            pendingUserMessages.removeValue(forKey: aiId)
        }
    }

    private actor StartSessionGate {
        private var inProgress: Set<UUID> = []
        private var waiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]

        /// - Returns: `true` if caller should perform the start; `false` if it waited for an in-flight start.
        func begin(_ aiId: UUID) async throws -> Bool {
            if !inProgress.contains(aiId) {
                inProgress.insert(aiId)
                return true
            }

            try await withCheckedThrowingContinuation { cont in
                waiters[aiId, default: []].append(cont)
            }
            return false
        }

        func end(_ aiId: UUID, result: Result<Void, Error>) {
            inProgress.remove(aiId)
            let conts = waiters.removeValue(forKey: aiId) ?? []
            for cont in conts {
                cont.resume(with: result)
            }
        }
    }

    private actor TerminalPromptMonitorState {
        private var tasks: [UUID: Task<Void, Never>] = [:]

        func hasTask(for aiId: UUID) -> Bool {
            tasks[aiId] != nil
        }

        func setTask(_ task: Task<Void, Never>, for aiId: UUID) {
            tasks[aiId] = task
        }

        func removeTask(for aiId: UUID) -> Task<Void, Never>? {
            tasks.removeValue(forKey: aiId)
        }
    }
    
    // MARK: - Session Lifecycle
    
    /// 为 AI 创建并启动 tmux 会话
    func startSession(for ai: AIInstance) async throws {
        let isCreator = try await startSessionGate.begin(ai.id)
        if !isCreator { return }

        do {
            try await performStartSession(for: ai)
            await startSessionGate.end(ai.id, result: .success(()))
        } catch {
            await startSessionGate.end(ai.id, result: .failure(error))
            throw error
        }
    }

    private func performStartSession(for ai: AIInstance) async throws {
        // 如果已经在运行，直接返回（避免重复注入 CLI command）
        let alreadyRunning = await MainActor.run {
            activeSessions[ai.id] != nil && sessionStatus[ai.id] == .running
        }
        if alreadyRunning {
            return
        }

        await MainActor.run {
            sessionStatus[ai.id] = .starting
        }

        let sessionName = ai.tmuxSession
        let workDir = ai.workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : ai.workingDirectory

        do {
            // 检查会话是否已存在
            let exists = try await sessionExists(sessionName)

            if !exists {
                // 创建新会话，直接以 CLI 作为 pane command 启动，避免通过 send-keys 注入导致的竞态条件：
                // - 旧实现：new-session 启动 shell → sleep → send-keys "codex" Enter
                // - 问题：shell 初始化时间不稳定，导致注入发生在 prompt 之前，命令丢失/错序
                //
                // 这里用 /bin/zsh -lc 确保读取用户的登录配置（尤其是 PATH），并把 CLI 作为首进程执行。
                // CLI 退出时会话自动结束（更安全：避免回到 shell prompt 后把聊天消息当成系统命令执行）。
                try await runTmux([
                    "new-session",
                    "-d",
                    "-s", sessionName,
                    "-c", workDir,
                    "/bin/zsh", "-lc", ai.type.cliCommand
                ])

                // 设置无限滚动历史缓冲区（0 = 无限制）
                try await runTmux([
                    "set-option", "-t", sessionName,
                    "history-limit", "0"
                ])
                
                // 简短确认：如果 CLI 立刻退出（例如未安装/权限/崩溃），tmux session 可能会马上消失。
                try await Task.sleep(nanoseconds: 120_000_000) // 120ms
                let stillExists = try await sessionExists(sessionName)
                if !stillExists {
                    throw SessionError.commandFailed("\(ai.type.cliCommand) exited immediately (tmux session ended)")
                }
            } else {
                // 会话已存在：不再重复注入 cliCommand，避免重复启动/污染输入缓冲区。
                // 如果旧会话异常结束，后续操作会触发错误并可提示重启。
            }

            // 记录会话
            await MainActor.run {
                activeSessions[ai.id] = sessionName
                sessionStatus[ai.id] = .running
            }

            // 启动“终端交互提示”监控（例如 Claude 的信任/权限确认）
            await startTerminalPromptMonitorIfNeeded(for: ai)

            print("✅ Session started: \(sessionName) for \(ai.name) in \(workDir)")
        } catch {
            await MainActor.run {
                sessionStatus[ai.id] = .error
            }
            throw error
        }
    }
    
    /// 停止 tmux 会话
    func stopSession(for ai: AIInstance) async throws {
        guard let sessionName = activeSessions[ai.id] else { return }

        await stopTerminalPromptMonitor(for: ai.id)

        // 杀死会话
        _ = try? await runTmux(["kill-session", "-t", sessionName])

        await MainActor.run {
            activeSessions.removeValue(forKey: ai.id)
            sessionStatus[ai.id] = .stopped
            terminalChoicePrompts.removeValue(forKey: ai.id)
        }

        print("🛑 Session stopped: \(sessionName)")
    }

    // MARK: - Terminal Prompts (Interactive Choice)

    /// 主动检查并更新“需要用户选择”的终端提示（目前主要用于 Claude）。
    /// - Returns: 若检测到提示则返回 prompt，否则返回 nil。
    @discardableResult
    func checkAndUpdateTerminalChoicePrompt(for ai: AIInstance, lines: Int = 200) async -> TerminalChoicePrompt? {
        do {
            let raw = try await captureOutput(from: ai, lines: lines)
            let prompt = detectTerminalChoicePrompt(in: raw)
            await MainActor.run {
                if let prompt {
                    terminalChoicePrompts[ai.id] = prompt
                } else {
                    terminalChoicePrompts.removeValue(forKey: ai.id)
                }
            }
            return prompt
        } catch {
            return nil
        }
    }

    /// 用户在聊天区选择某个选项后，把对应按键发送回终端（例如 `1` + Enter）。
    func submitTerminalChoice(_ number: Int, for ai: AIInstance) async throws {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        try await sendToSession(sessionName, text: String(number))

        await MainActor.run {
            _ = terminalChoicePrompts.removeValue(forKey: ai.id)
        }
    }

    private func startTerminalPromptMonitorIfNeeded(for ai: AIInstance) async {
        let alreadyStarted = await terminalPromptMonitorState.hasTask(for: ai.id)
        if alreadyStarted { return }

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                // 会话不存在/不在 running 就退出
                let isRunning = await MainActor.run {
                    self.activeSessions[ai.id] != nil && self.sessionStatus[ai.id] == .running
                }
                if !isRunning { break }

                _ = await self.checkAndUpdateTerminalChoicePrompt(for: ai, lines: 200)
                try? await Task.sleep(nanoseconds: 600_000_000) // 0.6s
            }

            await MainActor.run {
                _ = self.terminalChoicePrompts.removeValue(forKey: ai.id)
            }
        }
        await terminalPromptMonitorState.setTask(task, for: ai.id)
    }

    private func stopTerminalPromptMonitor(for aiId: UUID) async {
        let task = await terminalPromptMonitorState.removeTask(for: aiId)
        task?.cancel()
    }

    private func detectTerminalChoicePrompt(in content: String) -> TerminalChoicePrompt? {
        // 移除 ANSI 转义码
        let cleaned = content.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )

        // 保留空行（否则 split 默认会丢弃空子序列，导致段落空行消失）
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let tail = Array(lines.suffix(120))

        func isBoxNoiseLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            return trimmed.allSatisfy { ch in
                ch == "─" || ch == "━" || ch == "│" || ch == "┃" ||
                ch == "╭" || ch == "╮" || ch == "╰" || ch == "╯" ||
                ch == "┌" || ch == "┐" || ch == "└" || ch == "┘" ||
                ch == "┏" || ch == "┓" || ch == "┗" || ch == "┛" ||
                ch == " " || ch == "\t"
            }
        }

        func isConfirmHintLine(_ line: String) -> Bool {
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty else { return false }
            return lower.contains("enter to confirm") ||
                lower.contains("esc to exit") ||
                lower.contains("enter confirms") ||
                lower.contains("press enter") ||
                lower.contains("use arrow") ||
                lower.contains("select an option") ||
                lower.contains("choose an option")
        }

        func parseOptionLine(_ line: String) -> (number: Int, label: String)? {
            var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }

            // 选中指示符（不同 TUI 主题可能不同）
            let selectionMarkers: Set<Character> = [">", "›", "❯", "▶", "→", "•"]
            if let first = s.first, selectionMarkers.contains(first) {
                s.removeFirst()
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // 解析 "1. xxx" 或 "1) xxx"
            var digits = ""
            var idx = s.startIndex
            while idx < s.endIndex, s[idx].isNumber {
                digits.append(s[idx])
                idx = s.index(after: idx)
            }
            guard !digits.isEmpty, idx < s.endIndex else { return nil }

            let sep = s[idx]
            guard sep == "." || sep == ")" else { return nil }
            idx = s.index(after: idx)

            while idx < s.endIndex, s[idx] == " " || s[idx] == "\t" {
                idx = s.index(after: idx)
            }

            let label = String(s[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let number = Int(digits), !label.isEmpty else { return nil }
            return (number, label)
        }

        // 先从底部向上抓取连续的选项行（允许中间夹少量空行）。
        //
        // 注意：我们只关心“仍在等待用户选择”的交互态。
        // 某些 CLI（例如 Codex 的更新提示）在用户已选择后仍会把选项保留在 scrollback/history；
        // 这会导致仅靠“历史中出现过选项”就误判，进而让聊天区卡片反复出现。
        var options: [(index: Int, option: TerminalChoiceOption)] = []
        var i = tail.count - 1
        while i >= 0 {
            let line = tail[i]
            if let parsed = parseOptionLine(line) {
                options.insert((i, TerminalChoiceOption(number: parsed.number, label: parsed.label)), at: 0)
                i -= 1
                continue
            }

            if options.isEmpty {
                i -= 1
                continue
            }

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBoxNoiseLine(line) {
                i -= 1
                continue
            }

            break
        }

        guard options.count >= 2 else { return nil }

        let firstOptionIndex = options.first?.index ?? 0
        let lastOptionIndex = options.last?.index ?? 0

        // 若选项块后面还有“正常输出”，说明用户已完成选择并进入下一屏；忽略历史残留。
        if lastOptionIndex + 1 < tail.count {
            let trailing = tail[(lastOptionIndex + 1)...]
            let hasNonPromptTrailingOutput = trailing.contains(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                if isBoxNoiseLine(line) { return false }
                if isConfirmHintLine(line) { return false }
                return true
            })
            guard !hasNonPromptTrailingOutput else { return nil }
        }

        // 为避免误判：确认/退出提示语必须出现在“选项块附近”。
        let windowStart = max(0, firstOptionIndex - 15)
        let windowEnd = min(tail.count - 1, lastOptionIndex + 15)
        let hasConfirmHintInWindow = tail[windowStart...windowEnd].contains(where: { isConfirmHintLine($0) })
        guard hasConfirmHintInWindow else { return nil }

        // 取选项上方的一段上下文作为标题/说明
        let contextStart = max(0, firstOptionIndex - 12)
        let contextRaw = tail[contextStart..<firstOptionIndex]
        let context = contextRaw
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isBoxNoiseLine($0) }

        let title = context.first ?? "Action required"
        let body = context.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // footer hint：取最后一行包含 enter/esc 的提示文本
        let hint = tail
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { line in
                let l = line.lowercased()
                return l.contains("enter") || l.contains("esc")
            })

        return TerminalChoicePrompt(
            title: title,
            body: body.isEmpty ? nil : body,
            hint: hint,
            options: options.map(\.option)
        )
    }
    
    /// 检查会话是否存在
    func sessionExists(_ name: String) async throws -> Bool {
        let result = try await runTmux(["has-session", "-t", name])
        return result.exitCode == 0
    }
    
    // MARK: - Message Sending
    
    /// 发送消息到 AI 会话
    func sendMessage(_ message: String, to ai: AIInstance) async throws {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        // 任何 CLI 都可能进入“需要用户确认/选择”的交互状态；
        // 在该状态下发送聊天文本会被当成“选择输入”，因此这里统一阻塞。
        let cached = await MainActor.run { terminalChoicePrompts[ai.id] }
        if let cached {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(cached.title)")
        }
        if let detected = await checkAndUpdateTerminalChoicePrompt(for: ai) {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(detected.title)")
        }

        await transientState.setPendingUserMessage(message, for: ai.id)

        let userEvent = MessageDTO(
            id: UUID(),
            senderId: ai.id,
            senderType: "user",
            senderName: "You",
            content: message,
            timestamp: Date()
        )
        broadcastToRemote(aiId: ai.id, message: userEvent, isStreaming: false)

        // Claude：记录本轮发送上下文，后续提取只会绑定到“本轮 user → 对应 assistant”链
        if ai.type == .claude, let transcriptURL = ClaudeTranscriptExtractor.transcriptURL(for: ai.workingDirectory) {
            let baselineUserUuid = try? ClaudeTranscriptExtractor.latestUserUuid(workingDirectory: ai.workingDirectory)
            let context = ClaudePendingRequest(
                transcriptURL: transcriptURL,
                afterUserUuid: baselineUserUuid,
                expectedUserText: message,
                minTimestamp: Date()
            )
            await transientState.setClaudePendingRequest(context, for: ai.id)
        }
        
        try await sendToSession(sessionName, text: message)
    }
    
    /// 发送文本到 tmux 会话
    private func sendToSession(_ session: String, text: String) async throws {
        // 对于包含换行的多行文本，使用 tmux buffer 机制确保完整发送
        // 否则 send-keys 会把 \n 当作 Enter 键，导致 prompt 被拆成多次提交
        
        if text.contains("\n") {
            // 多行文本：写入临时文件 → load-buffer → paste-buffer
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("battlelm_prompt_\(UUID().uuidString).txt")
            
            do {
                try text.write(to: tempFile, atomically: true, encoding: .utf8)
                
                // 加载到 tmux buffer
                try await runTmux(["load-buffer", tempFile.path])
                
                // 粘贴到目标 session
                try await runTmux(["paste-buffer", "-t", session])
                
                // 稍等一下确保文本被粘贴
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                
                // 发送 Enter 键提交
                try await runTmux(["send-keys", "-t", session, "Enter"])
                
                // 清理临时文件
                try? FileManager.default.removeItem(at: tempFile)
            } catch {
                try? FileManager.default.removeItem(at: tempFile)
                throw error
            }
        } else {
            // 单行文本：使用原有的 send-keys -l 方式
            try await runTmux(["send-keys", "-t", session, "-l", text])
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            try await runTmux(["send-keys", "-t", session, "Enter"])
        }
    }
    
    // MARK: - Output Capture
    
    /// 捕获 AI 会话的输出
    /// 注意：`capture-pane -a` 只会读取 alternate screen；多数 CLI（Codex/Gemini/Kimi/Qwen）不使用 alternate screen，
    /// 直接加 `-a` 会导致 tmux 报错并返回空 stdout（进而导致“提取不到任何内容”）。
    func captureOutput(from ai: AIInstance, lines: Int = 10000) async throws -> String {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        // 优先策略：
        // - 非 Claude：先抓 normal screen + history（不带 -a），必要时再 fallback 到 -a
        // - Claude：终端 UI 常在 alternate screen，但提取回复走 JSONL；这里优先 -a 以保证 Snapshot 终端可见
        let attempts: [[String]]
        if ai.type == .claude {
            attempts = [
                ["capture-pane", "-t", sessionName, "-p", "-a"],
                ["capture-pane", "-t", sessionName, "-p", "-S", "-\(lines)"]
            ]
        } else {
            attempts = [
                ["capture-pane", "-t", sessionName, "-p", "-S", "-\(lines)"],
                ["capture-pane", "-t", sessionName, "-p", "-a"]
            ]
        }

        var lastError: String? = nil
        for args in attempts {
            let result = try await runTmux(args)
            if result.exitCode == 0 {
                return result.stdout
            }
            lastError = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw SessionError.commandFailed(lastError ?? "tmux capture-pane failed")
    }
    
    /// 流式获取 AI 响应，实时回调更新
    /// - Parameters:
    ///   - ai: AI 实例
    ///   - onUpdate: 每次内容变化时的回调，参数为 (当前内容, 是否正在思考, 是否已完成)
    ///   - stableSeconds: 判定完成的稳定时间（秒）
    ///   - maxWait: 最大等待时间（秒）
    func streamResponse(from ai: AIInstance,
                        onUpdate: @escaping (String, Bool, Bool) -> Void,
                        stableSeconds: Double = 4.0,
                        maxWait: Double = 120.0) async throws {
        var didBroadcastFinal = false
        let bridgedOnUpdate: (String, Bool, Bool) -> Void = { [weak self] content, isThinking, isComplete in
            onUpdate(content, isThinking, isComplete)
            guard let self else { return }
            guard isComplete, !didBroadcastFinal else { return }
            didBroadcastFinal = true
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let aiEvent = MessageDTO(
                id: UUID(),
                senderId: ai.id,
                senderType: "ai",
                senderName: ai.name,
                content: trimmed,
                timestamp: Date()
            )
            self.broadcastToRemote(aiId: ai.id, message: aiEvent, isStreaming: false)
        }

        // 🎯 Claude 专用路径：使用 transcript JSONL 提取（100% 可靠）
        if ai.type == .claude && ClaudeTranscriptExtractor.isTranscriptAvailable(for: ai.workingDirectory) {
            try await streamClaudeTranscript(from: ai, onUpdate: bridgedOnUpdate, stableSeconds: stableSeconds, maxWait: maxWait)
            return
        }
        
        // Fallback：其他 AI 或 Claude transcript 不可用时，使用传统 capture-pane 方式
        try await streamWithCapturPane(from: ai, onUpdate: bridgedOnUpdate, stableSeconds: stableSeconds, maxWait: maxWait)
    }
    
    /// Claude 专用：从 transcript JSONL 流式提取响应
    private func streamClaudeTranscript(from ai: AIInstance,
                                         onUpdate: @escaping (String, Bool, Bool) -> Void,
                                         stableSeconds: Double,
                                         maxWait: Double) async throws {
        print("📜 Using Claude Transcript Extractor for: \(ai.name)")
        let context = await transientState.claudePendingRequest(for: ai.id)

        guard let context else {
            // 允许在极端情况下（例如 app 重启/状态丢失）退化为“尽力而为”的提取，避免完全无响应
            if let transcriptURL = ClaudeTranscriptExtractor.transcriptURL(for: ai.workingDirectory) {
                _ = try await ClaudeTranscriptExtractor.streamLatestResponse(
                    transcriptURL: transcriptURL,
                    afterUserUuid: nil,
                    expectedUserText: nil,
                    minTimestamp: nil,
                    onUpdate: { content, isComplete in
                        onUpdate(content, false, isComplete)
                    },
                    stableSeconds: stableSeconds,
                    maxWait: maxWait
                )
                return
            }
            throw SessionError.sessionNotFound("Claude pending context missing for \(ai.name)")
        }
        
        _ = try await ClaudeTranscriptExtractor.streamLatestResponse(
            transcriptURL: context.transcriptURL,
            afterUserUuid: context.afterUserUuid,
            expectedUserText: context.expectedUserText,
            minTimestamp: context.minTimestamp,
            onUpdate: { content, isComplete in
                onUpdate(content, false, isComplete)
            },
            stableSeconds: stableSeconds,
            maxWait: maxWait
        )
        await transientState.clearClaudePendingRequest(for: ai.id)
    }
    
    /// 传统方式：使用 capture-pane 流式提取响应（用于非 Claude AI 或 fallback）
    private func streamWithCapturPane(from ai: AIInstance,
                                       onUpdate: @escaping (String, Bool, Bool) -> Void,
                                       stableSeconds: Double,
                                       maxWait: Double) async throws {
        let startTime = Date()
        var lastContent = ""
        var lastChangeTime = Date()
        var responseStarted = false

        let userMessage = await transientState.pendingUserMessage(for: ai.id)
        
        while Date().timeIntervalSince(startTime) < maxWait {
            let rawContent = try await captureOutput(from: ai)
            let response = extractResponse(from: rawContent, for: ai, userMessage: userMessage)
            
            // 检测是否正在思考（Thinking 状态）
            let isThinking = response.lowercased().contains("thinking") || 
                             response.lowercased().contains("envisioning") ||
                             response.lowercased().contains("enchanting") ||  // Claude 新版
                             response.contains("⁝") ||
                             response.contains("context:")
            
            // 检测响应是否已开始（检查原始输出是否包含响应前缀）
            let hasResponsePrefix = rawContent.contains("✦ ") || 
                                    rawContent.contains("● ") ||  // Claude
                                    rawContent.contains("• ") || 
                                    rawContent.contains("+ ")
            
            if hasResponsePrefix && !response.isEmpty {
                responseStarted = true
            }
            
            // 检查内容是否变化
            if response != lastContent {
                lastContent = response
                lastChangeTime = Date()
                
                // 回调更新（未完成）
                await MainActor.run {
                    onUpdate(response, isThinking, false)
                }
            } else if responseStarted && !isThinking {
                // 响应已开始且不是思考状态，检查稳定性
                if Date().timeIntervalSince(lastChangeTime) >= stableSeconds {
                    // 稳定足够时间，判定完成
                    await MainActor.run {
                        onUpdate(response, false, true)
                    }
                    await transientState.clearPendingUserMessage(for: ai.id)
                    return
                }
            }
            
            // 轮询间隔 300ms
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        
        // 超时，返回当前内容
        await MainActor.run {
            onUpdate(lastContent, false, true)
        }

        await transientState.clearPendingUserMessage(for: ai.id)
    }
    
    /// 等待 AI 响应完成（输出稳定）
    func waitForResponse(from ai: AIInstance, 
                         stableSeconds: Double = 3.0,
                         maxWait: Double = 60.0) async throws -> String {
        // 🎯 Claude 专用路径：使用 transcript JSONL 提取
        if ai.type == .claude && ClaudeTranscriptExtractor.isTranscriptAvailable(for: ai.workingDirectory) {
            print("📜 Using Claude Transcript Extractor for waitForResponse: \(ai.name)")
            let context = await transientState.claudePendingRequest(for: ai.id)

            guard let context else {
                if let transcriptURL = ClaudeTranscriptExtractor.transcriptURL(for: ai.workingDirectory) {
                    return try await ClaudeTranscriptExtractor.streamLatestResponse(
                        transcriptURL: transcriptURL,
                        afterUserUuid: nil,
                        expectedUserText: nil,
                        minTimestamp: nil,
                        onUpdate: { _, _ in },
                        stableSeconds: stableSeconds,
                        maxWait: maxWait
                    )
                }
                throw SessionError.sessionNotFound("Claude pending context missing for \(ai.name)")
            }
            
            // 复用 stream 逻辑等待本轮内容稳定
            let response = try await ClaudeTranscriptExtractor.streamLatestResponse(
                transcriptURL: context.transcriptURL,
                afterUserUuid: context.afterUserUuid,
                expectedUserText: context.expectedUserText,
                minTimestamp: context.minTimestamp,
                onUpdate: { _, _ in },
                stableSeconds: stableSeconds,
                maxWait: maxWait
            )

            await transientState.clearClaudePendingRequest(for: ai.id)
            
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let aiEvent = MessageDTO(
                    id: UUID(),
                    senderId: ai.id,
                    senderType: "ai",
                    senderName: ai.name,
                    content: trimmed,
                    timestamp: Date()
                )
                broadcastToRemote(aiId: ai.id, message: aiEvent, isStreaming: false)
            }
            return response
        }
        
        // Fallback：传统 capture-pane 方式
        let startTime = Date()
        var lastContent = ""
        var lastChangeTime = Date()

        let userMessage = await transientState.pendingUserMessage(for: ai.id)
        
        while Date().timeIntervalSince(startTime) < maxWait {
            let content = try await captureOutput(from: ai, lines: 10000)
            
            if content != lastContent {
                lastContent = content
                lastChangeTime = Date()
            } else {
                // 检查是否稳定足够时间
                if Date().timeIntervalSince(lastChangeTime) >= stableSeconds {
                    let response = extractResponse(from: content, for: ai, userMessage: userMessage)
                    await transientState.clearPendingUserMessage(for: ai.id)
                    let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let aiEvent = MessageDTO(
                            id: UUID(),
                            senderId: ai.id,
                            senderType: "ai",
                            senderName: ai.name,
                            content: trimmed,
                            timestamp: Date()
                        )
                        broadcastToRemote(aiId: ai.id, message: aiEvent, isStreaming: false)
                    }
                    return response
                }
            }
            
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒
        }
        
        throw SessionError.timeout
    }
    
    // MARK: - Response Extraction
    
    /// 从 tmux 输出中提取最新的 AI 响应（非 Claude）
    /// 参考 codex-telegram/gemini-telegram 的策略：先定位本轮用户输入行（含 Unicode 前缀），再提取其后的 AI 响应块。
    private func extractResponse(from content: String, for ai: AIInstance, userMessage: String?) -> String {
        // 移除 ANSI 转义码
        let cleaned = content.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        
        // 保留空行（否则 split 默认会丢弃空子序列，导致段落空行消失）
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }

        // 不同 CLI 使用不同的提示符/前缀（尤其是 Codex 的 ›）
        let userPrefixes: [String]
        let responsePrefixes: [String]
        switch ai.type {
        case .codex:
            userPrefixes = ["›"] // U+203A
            responsePrefixes = ["•"] // U+2022
        case .gemini:
            userPrefixes = [">"]
            responsePrefixes = ["+", "•", "✦", "*"]
        case .qwen, .kimi:
            userPrefixes = [">"]
            responsePrefixes = ["+", "•", "✦", "*"]
        case .claude:
            userPrefixes = [">"]
            responsePrefixes = ["✦", "●", "•", "+"]
        }
        let boxChars = Set("╭╮╰╯│─┌┐└┘├┤┬┴┼━┃┏┓┗┛┣┫┳┻╋║═╔╗╚╝╠╣╦╩╬")

        func normalize(_ s: String) -> String {
            s.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func userLineMatches(_ afterPrompt: String, _ userMessage: String?) -> Bool {
            guard let userMessage, !userMessage.isEmpty else { return true }
            let msg = normalize(userMessage)
            let line = normalize(afterPrompt)
            if msg.isEmpty { return true }

            // Codex：telegram 实现里用 contains / 前缀匹配（避免 Unicode/标点差异）
            if ai.type == .codex {
                if line.contains(msg) { return true }
                let prefix = String(msg.prefix(min(8, msg.count)))
                return !prefix.isEmpty && line.hasPrefix(prefix)
            }

            // 其他：用较短前缀匹配，避免长文本在 tmux 中被截断显示
            let prefix = String(msg.prefix(min(15, msg.count)))
            return line.contains(prefix) || (line.count >= 3 && msg.contains(String(line.prefix(min(8, line.count)))))
        }
        
        // 第一步：从后往前找最后一个“本轮用户输入行”
        var lastUserInputIndex: Int? = nil
        
        for i in stride(from: lines.count - 1, through: 0, by: -1) {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            
            // 跳过空行和终端提示（注意：实际可能有多余空格）
            if trimmed.isEmpty || trimmed.contains("Type your message") {
                continue
            }
            
            // 找到用户输入行
            var matched = false
            for prefix in userPrefixes {
                if trimmed.hasPrefix(prefix) {
                    let afterPrompt = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    if afterPrompt.isEmpty || afterPrompt == "|" {
                        continue
                    }
                    if !userLineMatches(afterPrompt, userMessage) {
                        continue
                    }
                    lastUserInputIndex = i
                    matched = true
                    break
                }
            }
            if matched {
                break
            }
        }

        // 关键：找不到用户输入行就不要从头扫描（否则会把顶部横幅当成回复，稳定得到空）
        guard let lastUserInputIndex else { return "" }
        let searchStartIndex = lastUserInputIndex + 1
        
        // 第二步：从用户输入之后找响应前缀行
        var responseStartIndex: Int? = nil
        
        for i in searchStartIndex..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            
            // 找到以响应前缀开头的行
            for prefix in responsePrefixes {
                if trimmed.hasPrefix(prefix) {
                    responseStartIndex = i
                    break
                }
            }
            
            if responseStartIndex != nil {
                break
            }
        }
        
        guard let startIndex = responseStartIndex else {
            return ""
        }
        
        // 从找到的起始位置收集响应（收集所有行，不仅仅是前缀行）
        var responseLines: [String] = []
        
        // 终端元数据模式（不是 AI 响应内容）
        let terminalMetaPatterns = [
            // Claude
            "Envisioning",          // Claude 思考状态
            "Enchanting",           // Claude 思考状态（新版）
            "Thinking",             // Claude 思考状态
            "(esc to interrupt)",   // Claude 思考提示
            // Gemini
            "Using:",           // 半角冒号
            "Using：",          // 全角冒号
            "Ask Gemini",
            ".md file",
            // Codex
            "context left",
            "for shortcuts",
            "Type your message",
            "Explain this codebase",
            "Summarize recent commits",
            "% context",
            // Kimi
            "Welcome to Kimi",
            "Send /help",
            "upgrade kimi-cli",
            "context:",         // Kimi 底部状态如 context: 3.0%
            "New version available"
        ]
        
        for i in startIndex..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            
            // 停止条件：遇到边框字符
            if trimmed.contains(where: { boxChars.contains($0) }) {
                break
            }
            
            // 停止条件：遇到新的用户提示符（空的 > 提示）
            var isNextUserPrompt = false
            for prefix in userPrefixes {
                if trimmed.hasPrefix(prefix) {
                    isNextUserPrompt = true
                    break
                }
            }
            if isNextUserPrompt {
                break
            }
            
            // 停止条件：遇到终端元数据
            if terminalMetaPatterns.contains(where: { trimmed.contains($0) }) {
                break
            }
            
            // 保留空行以维持段落格式
            if trimmed.isEmpty {
                responseLines.append("")
                continue
            }
            
            // 移除响应前缀符号（如果有的话）
            var line = trimmed
            for prefix in responsePrefixes {
                if line.hasPrefix(prefix) {
                    line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            
            if !line.isEmpty {
                responseLines.append(line)
            }
        }
        
        return responseLines.joined(separator: "\n")
    }
    
    // MARK: - Tmux Helper
    
    /// BattleLM 使用独立的 tmux server socket，避免影响用户自己的 tmux
    private let tmuxSocket = "battlelm"
    
    @discardableResult
    private func runTmux(_ args: [String]) async throws -> CommandResult {
        // 使用独立 socket (-L battlelm) 隔离用户的 tmux 配置
        let tmuxCommand = (["/opt/homebrew/bin/tmux", "-L", tmuxSocket] + args).joined(separator: " ")
        return try await runShellCommand(tmuxCommand)
    }
    
    private func runShellCommand(_ command: String) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", command]
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe
            
            // 设置环境变量确保能找到 homebrew
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            task.environment = environment
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                
                let result = CommandResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: task.terminationStatus
                )
                
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

// MARK: - Supporting Types

struct TerminalChoiceOption: Identifiable, Equatable {
    let number: Int
    let label: String

    var id: Int { number }
}

struct TerminalChoicePrompt: Equatable {
    let title: String
    let body: String?
    let hint: String?
    let options: [TerminalChoiceOption]
}

struct CommandResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum SessionStatus: String {
    case starting
    case running
    case stopped
    case error
}

enum SessionError: LocalizedError {
    case sessionNotFound(String)
    case userActionRequired(String)
    case timeout
    case commandFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let name):
            return "Session not found for \(name)"
        case .userActionRequired(let message):
            return message
        case .timeout:
            return "Waiting for response timed out"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        }
    }
}
