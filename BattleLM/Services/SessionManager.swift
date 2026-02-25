// BattleLM/Services/SessionManager.swift
import Foundation
import Combine

/// tmux 会话管理器
class SessionManager: ObservableObject {
    static let shared = SessionManager()

    // 终端的交互式菜单有时会被 CLI 留在 scrollback 中（即便用户已完成选择）。
    // 若不做抑制，聊天区的选择卡片会在监控轮询中“死灰复燃”。
    // 这里使用一个偏保守的较长 TTL：大幅降低复燃概率，同时保留“稍后仍可能重新出现”的逃生口。
    private let dismissedTerminalPromptTTLSeconds: Double = 30 * 60
    
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
    private let terminalPromptDismissalState = TerminalPromptDismissalState()
    
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

        enum BeginPendingUserMessageResult {
            case started
            case duplicate
            case busy(existing: String)
        }

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

        func beginPendingUserMessage(_ message: String, for aiId: UUID) -> BeginPendingUserMessageResult {
            if let existing = pendingUserMessages[aiId] {
                if existing == message {
                    return .duplicate
                }
                return .busy(existing: existing)
            }
            pendingUserMessages[aiId] = message
            return .started
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

    private actor TerminalPromptDismissalState {
        private var dismissed: [UUID: (signature: String, at: Date)] = [:]

        func markDismissed(signature: String, for aiId: UUID, at date: Date = Date()) {
            dismissed[aiId] = (signature: signature, at: date)
        }

        func isRecentlyDismissed(signature: String, for aiId: UUID, ttlSeconds: Double) -> Bool {
            guard let entry = dismissed[aiId] else { return false }
            guard entry.signature == signature else { return false }
            return Date().timeIntervalSince(entry.at) <= ttlSeconds
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
        let rawWorkDir = ai.workingDirectory.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : ai.workingDirectory
        let workDir = (rawWorkDir as NSString).expandingTildeInPath

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
                    // Detached session needs an explicit size; otherwise early output may be hard-wrapped
                    // at tmux's default (often ~80 cols), and won't reflow later.
                    "-x", "120",
                    "-y", "40",
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

    private func terminalChoicePromptSignature(_ prompt: TerminalChoicePrompt) -> String {
        let normalizedTitle = prompt.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBody = (prompt.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHint = (prompt.hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let options = prompt.options
            .map { "\($0.number):\($0.label.trimmingCharacters(in: .whitespacesAndNewlines))" }
            .joined(separator: "|")
        return "\(normalizedTitle)\n\(normalizedBody)\n\(normalizedHint)\n\(options)"
    }

    private func shouldConsiderAlternateScreenForPrompts(for ai: AIInstance) -> Bool {
        // 一些 CLI（例如 Gemini/Qwen 的部分菜单）会使用 alternate screen 来渲染选择菜单/面板。
        // Claude 的 UI 也常在 alternate screen（但 Claude 主回复走 transcript/JSONL）。
        switch ai.type {
        case .gemini, .qwen, .claude:
            return true
        default:
            return false
        }
    }

    private func captureOutputsForPromptDetection(from ai: AIInstance, lines: Int) async throws -> (normal: String, alternate: String?) {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        let normalResult = try await runTmux(["capture-pane", "-t", sessionName, "-p", "-S", "-\(lines)"])
        let normal = normalResult.exitCode == 0 ? normalResult.stdout : ""

        guard shouldConsiderAlternateScreenForPrompts(for: ai) else {
            return (normal: normal, alternate: nil)
        }

        let altResult = try await runTmux(["capture-pane", "-t", sessionName, "-p", "-a"])
        let alt = altResult.exitCode == 0 ? altResult.stdout : nil
        return (normal: normal, alternate: alt)
    }

    private func captureAlternateScreen(from ai: AIInstance) async throws -> String? {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }
        guard shouldConsiderAlternateScreenForPrompts(for: ai) else { return nil }
        let altResult = try await runTmux(["capture-pane", "-t", sessionName, "-p", "-a"])
        return altResult.exitCode == 0 ? altResult.stdout : nil
    }

    /// 主动检查并更新“需要用户选择”的终端提示（目前主要用于 Claude）。
    /// - Returns: 若检测到提示则返回 prompt，否则返回 nil。
    @discardableResult
    func checkAndUpdateTerminalChoicePrompt(for ai: AIInstance, lines: Int = 200) async -> TerminalChoicePrompt? {
        do {
            // 先抓 normal screen（大多数 CLI 都在这里）；只有没检测到提示时，才尝试 alternate screen（避免监控线程过重）。
            let normal = try await captureOutput(from: ai, lines: lines)
            let promptInNormal = detectTerminalChoicePrompt(in: normal)
            let promptInAlt: TerminalChoicePrompt? = {
                guard promptInNormal == nil else { return nil }
                // captureAlternateScreen is async, handled separately below
                return nil
            }()
            
            var finalPromptInAlt = promptInAlt
            if promptInNormal == nil {
                if let alt = try? await captureAlternateScreen(from: ai) {
                    finalPromptInAlt = detectTerminalChoicePrompt(in: alt)
                }
            }

            let prompt = promptInNormal ?? finalPromptInAlt

            if let prompt {
                let signature = terminalChoicePromptSignature(prompt)
                let suppressed = await terminalPromptDismissalState.isRecentlyDismissed(
                    signature: signature,
                    for: ai.id,
                    ttlSeconds: dismissedTerminalPromptTTLSeconds
                )
                if suppressed {
                    await MainActor.run { terminalChoicePrompts.removeValue(forKey: ai.id) }
                    return nil
                }
            }

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

        let dismissedPrompt = await MainActor.run { terminalChoicePrompts[ai.id] }

        // ⚠️ 不要无条件发送 Enter：
        // 一些 CLI 的菜单在输入数字后会“立即进入下一层菜单”（例如 Codex /model 的二级选择：high/medium/low）。
        // 若这里固定追加 Enter，会把它当作“下一层菜单”的确认键，从而自动选择默认项（常见为 medium）。
        //
        // 策略：
        // 1) 先发送选择（数字或箭头），不立即 Enter。
        // 2) 等待终端刷新后探测当前 prompt：
        //    - 若已进入新 prompt，则直接展示新 prompt。
        //    - 若仍停留在同一 prompt 且 hint 明确要求 Enter，则再发送 Enter 完成确认。

        if let dismissedPrompt, (dismissedPrompt.hint ?? "").lowercased().contains("arrow") {
            // 箭头菜单（无编号）：把 option.number 视作 1-based index，通过上下键移动后 Enter。
            let raw = try await captureOutput(from: ai, lines: 240)
            if let state = detectArrowMenuState(in: raw, expected: dismissedPrompt.options) {
                let targetIndex = max(0, min(dismissedPrompt.options.count - 1, number - 1))
                let delta = targetIndex - state.selectedIndex

                let directionKey = delta >= 0 ? "Down" : "Up"
                let steps = abs(delta)
                if steps > 0 {
                    for _ in 0..<steps {
                        _ = try? await runTmux(["send-keys", "-t", sessionName, directionKey])
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
                }
                _ = try? await runTmux(["send-keys", "-t", sessionName, "Enter"])
            } else {
                // Best-effort fallback：仍尝试直接发送数字（某些菜单也支持数字快捷键）
                let sendResult = try await runTmux(["send-keys", "-t", sessionName, "-l", String(number)])
                if sendResult.exitCode != 0 {
                    let message = sendResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw SessionError.commandFailed(message.isEmpty ? "tmux send-keys failed" : message)
                }
            }
        } else {
            // 编号菜单：先发送数字，不立即 Enter。
            let sendResult = try await runTmux(["send-keys", "-t", sessionName, "-l", String(number)])
            if sendResult.exitCode != 0 {
                let message = sendResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.commandFailed(message.isEmpty ? "tmux send-keys failed" : message)
            }
        }

        try? await Task.sleep(nanoseconds: 180_000_000) // 180ms

        // 探测是否进入了新一层 prompt
        let after = await checkAndUpdateTerminalChoicePrompt(for: ai, lines: 240)

        // 仍在同一个 prompt：只有在 hint 明确要求 Enter 时才补发 Enter。
        if let dismissedPrompt,
           let after,
           after == dismissedPrompt,
           (dismissedPrompt.hint ?? "").lowercased().contains("enter") {
            _ = try? await runTmux(["send-keys", "-t", sessionName, "Enter"])
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms
            _ = await checkAndUpdateTerminalChoicePrompt(for: ai, lines: 240)
        }

        // 只有在“已离开当前 prompt”时才标记 dismissed（避免把同一菜单仍在等待确认时误抑制掉）
        let nowPrompt = await MainActor.run { terminalChoicePrompts[ai.id] }
        if let dismissedPrompt, nowPrompt != dismissedPrompt {
            await terminalPromptDismissalState.markDismissed(
                signature: terminalChoicePromptSignature(dismissedPrompt),
                for: ai.id
            )
        }
    }

    private func detectArrowMenuState(in content: String, expected: [TerminalChoiceOption]) -> (selectedIndex: Int, labels: [String])? {
        guard !expected.isEmpty else { return nil }
        let expectedLabels = expected.map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }

        let cleaned = content.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let tail = Array(lines.suffix(220))

        struct ArrowLine {
            let index: Int
            let label: String
            let isSelected: Bool
        }

        let selectedMarkers: Set<Character> = ["●", ">", "›", "❯", "▶", "→", "✓"]
        let unselectedMarkers: Set<Character> = ["○", "•"]

        func parseArrowLine(_ line: String, at index: Int) -> ArrowLine? {
            var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            // strip leading box border if present
            let leadingBoxBorders: Set<Character> = ["│", "┃", "║", "|"]
            if let first = s.first, leadingBoxBorders.contains(first) {
                let rest = s.dropFirst()
                if let next = rest.first, next == " " || next == "\t" {
                    s = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            guard let marker = s.first else { return nil }
            guard selectedMarkers.contains(marker) || unselectedMarkers.contains(marker) else { return nil }
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }

            // 避免把 "1. xxx" 误当成箭头菜单项
            if s.first?.isNumber == true { return nil }

            let isSelected = selectedMarkers.contains(marker)
            return ArrowLine(index: index, label: s, isSelected: isSelected)
        }

        let arrowLines: [ArrowLine] = tail.enumerated().compactMap { idx, line in
            parseArrowLine(line, at: idx)
        }
        guard arrowLines.count >= 2 else { return nil }

        // cluster blocks
        let maxGap = 8
        var blocks: [[ArrowLine]] = []
        for item in arrowLines {
            if var last = blocks.last, let prev = last.last, item.index - prev.index <= maxGap {
                last.append(item)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([item])
            }
        }

        func normalized(_ labels: [String]) -> [String] {
            labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        // pick the block whose labels match expected exactly (or as prefix), closest to bottom
        for block in blocks.reversed() {
            let labels = normalized(block.map(\.label))
            if labels == expectedLabels || (labels.count >= expectedLabels.count && Array(labels.prefix(expectedLabels.count)) == expectedLabels) {
                let selectedIndex = block.firstIndex(where: { $0.isSelected }) ?? 0
                return (selectedIndex: selectedIndex, labels: labels)
            }
        }

        // fallback: pick the bottom-most block with same count
        if let block = blocks.reversed().first(where: { $0.count == expected.count }) {
            let labels = normalized(block.map(\.label))
            let selectedIndex = block.firstIndex(where: { $0.isSelected }) ?? 0
            return (selectedIndex: selectedIndex, labels: labels)
        }

        return nil
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
                lower.contains("esc to close") ||
                lower.contains("esc to dismiss") ||
                lower.contains("press esc") ||
                lower.contains("press escape") ||
                lower.contains("enter confirms") ||
                lower.contains("press enter") ||
                lower.contains("enter to select") ||
                (lower.contains("use enter") && (lower.contains("select") || lower.contains("choose"))) ||
                lower.contains("use arrow") ||
                lower.contains("select an option") ||
                lower.contains("choose an option")
        }

        func parseOptionLine(_ line: String) -> (number: Int, label: String)? {
            var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }

            // 一些 TUI 会把菜单渲染在 box 内，选项行行首会带边框字符：
            // 例如 "│ 1. Auto" / "┃ ● 2. Pro"
            // 这里剥离单个“行首边框 + 空白”，让后续能够解析 "1. ..."。
            let leadingBoxBorders: Set<Character> = ["│", "┃", "║", "|"]
            if let first = s.first, leadingBoxBorders.contains(first) {
                let rest = s.dropFirst()
                if let next = rest.first, next == " " || next == "\t" {
                    s = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            // 选中指示符（不同 TUI 主题可能不同）
            // 说明：Gemini 的选择列表常用 "●"(U+25CF) 表示选中项（与 "•"(U+2022) 不同）。
            let selectionMarkers: Set<Character> = [">", "›", "❯", "▶", "→", "•", "●", "○", "✓"]
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

            var label = String(s[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
            // 有些 TUI 会在行尾也加边框，去掉尾部边框字符。
            if let last = label.last, leadingBoxBorders.contains(last) {
                label = String(label.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let number = Int(digits), !label.isEmpty else { return nil }
            return (number, label)
        }

        // 选项菜单的常见格式并不总是“连续的选项行”：
        // - Gemini/Codex 的 model picker 往往在每个选项行下面还有缩进的说明行
        // - 一些 CLI 会把选项行之间夹入空行/框线/提示文本
        //
        // 因此这里从 tail 中提取所有 option 行，并在时间（行号）上聚类成 block，
        // 选择“最靠近底部且带确认提示语”的 block 作为当前等待用户选择的菜单。
        let optionLines: [(index: Int, option: TerminalChoiceOption)] = tail.enumerated().compactMap { idx, line in
            guard let parsed = parseOptionLine(line) else { return nil }
            return (idx, TerminalChoiceOption(number: parsed.number, label: parsed.label))
        }

        guard optionLines.count >= 2 else { return nil }

        // 将 option 行按距离分组：允许 option 与 option 之间夹若干说明/空行。
        let maxGapBetweenOptionLines = 10
        var blocks: [[(index: Int, option: TerminalChoiceOption)]] = []
        for item in optionLines {
            if var last = blocks.last, let prev = last.last, item.index - prev.index <= maxGapBetweenOptionLines {
                last.append(item)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append([item])
            }
        }

        // 从底部向上选择最可能的 block
        guard let chosen = blocks
            .reversed()
            .first(where: { block in
                guard block.count >= 2 else { return false }
                let first = block.first?.index ?? 0
                let last = block.last?.index ?? 0
                let windowStart = max(0, first - 15)
                let windowEnd = min(tail.count - 1, last + 15)
                return tail[windowStart...windowEnd].contains(where: { isConfirmHintLine($0) })
            }) else {
                return nil
            }

        let options = chosen
        let firstOptionIndex = chosen.first?.index ?? 0
        let lastOptionIndex = chosen.last?.index ?? 0

        // 若选项块后面出现“正常聊天输入提示/主提示符”，有两种情况：
        // 1) 这是 overlay 菜单（例如 /model）——菜单还在，输入提示符可能仍可见（应继续显示卡片）
        // 2) 这是历史残留（旧菜单留在 scrollback）——菜单已经结束（应避免卡片反复出现）
        //
        // 这里采用一个保守、低风险的判定：只有当“菜单块之后还有大量内容”且出现输入提示符时，
        // 才认为是历史残留；否则仍视为需要用户操作。
        if lastOptionIndex + 1 < tail.count {
            let trailing = tail[(lastOptionIndex + 1)...]
            let indicatesBackToNormalPrompt = trailing.contains(where: { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return false }
                let lower = trimmed.lowercased()
                if lower.contains("type your message") { return true }
                if lower.contains("@path/to/file") { return true }
                if lower.contains("context left") { return true }
                if trimmed.hasPrefix("›") { return true }
                return false
            })

            let trailingLineCount = tail.count - 1 - lastOptionIndex
            if indicatesBackToNormalPrompt && trailingLineCount >= 28 {
                return nil
            }
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

    private func isQwenShellModeEnabled(in content: String) -> Bool {
        let cleaned = content.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        return cleaned.lowercased().contains("shell mode enabled")
    }

    private func tryExitQwenShellModeIfNeeded(for ai: AIInstance) async {
        guard ai.type == .qwen else { return }
        do {
            let tail = try await captureOutput(from: ai, lines: 120)
            guard isQwenShellModeEnabled(in: tail) else { return }
            guard let sessionName = activeSessions[ai.id] else { return }
            _ = try? await runTmux(["send-keys", "-t", sessionName, "Escape"])
            try? await Task.sleep(nanoseconds: 120_000_000) // 120ms
        } catch {
            // Best-effort: do not block sending on a flaky capture.
        }
    }
    
    /// 向指定 AI 会话发送 Escape 键，中断当前 AI 输出
    /// - Parameter aiIds: 要中断的 AI ID 集合。若为空则中断所有活跃会话。
    func sendEscapeToSessions(for aiIds: Set<UUID>? = nil) async {
        let targets = aiIds ?? Set(activeSessions.keys)
        for aiId in targets {
            guard let sessionName = activeSessions[aiId] else { continue }
            _ = try? await runTmux(["send-keys", "-t", sessionName, "Escape"])
        }
    }
    
    /// 清理指定 AI 的 pending 消息状态
    func clearPendingMessages(for aiIds: Set<UUID>) async {
        for aiId in aiIds {
            await transientState.clearPendingUserMessage(for: aiId)
        }
    }

    /// 发送后校验：若文本仍停留在输入区（未真正提交），自动补发 Enter。
    /// 这是一个 best-effort 的防抖机制，覆盖 Gemini/Codex/Qwen/Kimi/Claude 的偶发“Enter 吞键”场景。
    private func ensureSubmittedIfNeeded(text: String, for ai: AIInstance, sessionName: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 最多补发两次 Enter，避免极端情况下无限重试。
        for attempt in 1...2 {
            try? await Task.sleep(nanoseconds: 180_000_000) // 180ms
            guard let tail = try? await captureOutput(from: ai, lines: 140) else { return }
            guard messageLikelyStillInInputArea(trimmed, terminalContent: tail, ai: ai) else { return }
            _ = try? await runTmux(["send-keys", "-t", sessionName, "Enter"])
            if attempt == 2 { return }
        }
    }

    private func messageLikelyStillInInputArea(_ message: String, terminalContent: String, ai: AIInstance) -> Bool {
        let compactMsg = message.lowercased().filter { !$0.isWhitespace }
        let suffix = String(compactMsg.suffix(56))
        guard suffix.count >= 6 else { return false }

        let cleaned = terminalContent.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let tailLines = Array(lines.suffix(12))
        guard !tailLines.isEmpty else { return false }

        // 优先：命中“底部几行”的输入行（最接近当前 cursor 所在区域）。
        let bottomLines = tailLines.suffix(4)
        for line in bottomLines {
            let compactLine = line.lowercased().filter { !$0.isWhitespace }
            if compactLine.contains(suffix), isLikelyInputLine(line, for: ai) {
                return true
            }
        }

        // 兜底：有些 REPL 会换行折叠输入，按尾部窗口拼接判断（与旧 Qwen 修复思路一致）。
        let tailCompact = tailLines.joined(separator: "\n").lowercased().filter { !$0.isWhitespace }
        guard tailCompact.contains(suffix) else { return false }
        return bottomLines.contains(where: { isLikelyInputLine($0, for: ai) })
    }

    private func isLikelyInputLine(_ line: String, for ai: AIInstance) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        if trimmed.hasPrefix(">") || trimmed.hasPrefix("›") || trimmed.hasPrefix("$") {
            return true
        }
        if lower.contains("type your message") { return true }
        if lower.contains("@path/to/file") { return true }
        if lower.contains("context left") { return true }
        if lower.contains("no sandbox") && (lower.contains("auto") || lower.contains("workspace")) { return true }
        // Kimi 的输入行常见形态：<username>✨ <message>
        if ai.type == .kimi, trimmed.contains("✨") { return true }
        return false
    }
    
    /// 发送消息到 AI 会话
    func sendMessage(_ message: String, to ai: AIInstance) async throws {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        // Kimi CLI 采用“单行提交”交互：粘贴/注入的换行会被当作多次 Enter 提交，
        // 这会把 Round2/3 多行 prompt 拆成多条用户消息（出现大量 `username✨ ...` 回显），
        // 进而污染讨论流程并导致提取/稳定判定错误。
        //
        // 因此对 Kimi 统一将多行文本压为单行再发送，避免拆包。
        let terminalMessage: String = {
            guard ai.type == .kimi else { return message }
            return collapseMultilineForSingleLineREPL(message)
        }()

        // 任何 CLI 都可能进入“需要用户确认/选择”的交互状态；
        // 在该状态下发送聊天文本会被当成“选择输入”，因此这里统一阻塞。
        let cached = await MainActor.run { terminalChoicePrompts[ai.id] }
        if let cached {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(cached.title)")
        }
        if let detected = await checkAndUpdateTerminalChoicePrompt(for: ai) {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(detected.title)")
        }

        // Qwen：如果误入 shell mode（esc to disable），先退出再发送。
        await tryExitQwenShellModeIfNeeded(for: ai)

        let beginResult = await transientState.beginPendingUserMessage(terminalMessage, for: ai.id)
        switch beginResult {
        case .started:
            break
        case .duplicate:
            // 同一条消息已在等待回复，避免重复注入（会导致终端重复出现同一句）
            return
        case .busy(let existing):
            throw SessionError.busy("\(ai.name) is still responding to: \(existing)")
        }

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
        
        do {
            try await sendToSession(sessionName, text: terminalMessage)
            await ensureSubmittedIfNeeded(text: terminalMessage, for: ai, sessionName: sessionName)
        } catch {
            await transientState.clearPendingUserMessage(for: ai.id)
            if ai.type == .claude {
                await transientState.clearClaudePendingRequest(for: ai.id)
            }
            throw error
        }
    }

    /// 发送“终端控制指令”（通常以 `/` 开头，例如 `/status`、`/model`）。
    ///
    /// 这些指令往往不会产生可被 `extractResponse` 识别的“AI 回复块”，而是：
    /// - 直接打印一段 TUI/状态面板
    /// - 或进入菜单态等待用户选择
    ///
    /// 因此它们不应进入 `pendingUserMessage` + stream/wait 的“聊天问答”状态机。
    func sendTerminalCommand(_ command: String, to ai: AIInstance) async throws {
        guard let sessionName = activeSessions[ai.id] else {
            throw SessionError.sessionNotFound(ai.name)
        }

        // 如果仍有上一轮“聊天问答”在等待回复，避免混入控制指令破坏交互态。
        if let existing = await transientState.pendingUserMessage(for: ai.id) {
            throw SessionError.busy("\(ai.name) is still responding to: \(existing)")
        }

        // 若终端正在等待用户确认/选择，先让用户完成确认再发送（否则会被当作选项输入）。
        let cached = await MainActor.run { terminalChoicePrompts[ai.id] }
        if let cached {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(cached.title)")
        }
        if let detected = await checkAndUpdateTerminalChoicePrompt(for: ai) {
            throw SessionError.userActionRequired("\(ai.name) is waiting for your confirmation: \(detected.title)")
        }

        // Qwen：如果误入 shell mode（esc to disable），先退出再发送。
        await tryExitQwenShellModeIfNeeded(for: ai)

        try await sendToSession(sessionName, text: command)
        await ensureSubmittedIfNeeded(text: command, for: ai, sessionName: sessionName)
    }

    /// 对于“终端控制指令”，从终端输出中提取其打印的内容（例如 `/status` 的面板）。
    /// - Returns: 若指令触发了菜单态（TerminalChoicePrompt），返回 nil（由卡片接管交互）。
    func captureTerminalCommandOutput(for ai: AIInstance, command: String, maxWait: Double = 3.0) async throws -> String? {
        let start = Date()
        var last: String = ""
        var lastChange = Date()

        while Date().timeIntervalSince(start) < maxWait {
            let captures = try await captureOutputsForPromptDetection(from: ai, lines: 240)

            let prompt = detectTerminalChoicePrompt(in: captures.normal)
                ?? captures.alternate.flatMap { detectTerminalChoicePrompt(in: $0) }

            if let prompt {
                let signature = terminalChoicePromptSignature(prompt)
                let suppressed = await terminalPromptDismissalState.isRecentlyDismissed(
                    signature: signature,
                    for: ai.id,
                    ttlSeconds: dismissedTerminalPromptTTLSeconds
                )
                if !suppressed {
                    await MainActor.run { terminalChoicePrompts[ai.id] = prompt }
                    return nil
                }
            }

            let outputNormal = extractTerminalCommandPrintedBlock(from: captures.normal, for: ai, command: command) ?? ""
            let outputAlt = captures.alternate.flatMap { extractTerminalCommandPrintedBlock(from: $0, for: ai, command: command) } ?? ""
            let output = (outputAlt.trimmingCharacters(in: .whitespacesAndNewlines).count > outputNormal.trimmingCharacters(in: .whitespacesAndNewlines).count)
                ? outputAlt
                : outputNormal

            if output != last {
                last = output
                lastChange = Date()
            } else if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 输出稳定一小段时间后返回（避免只抓到半屏 TUI）
                if Date().timeIntervalSince(lastChange) >= 0.35 {
                    return output
                }
            }

            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        return last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : last
    }

    private func extractTerminalCommandPrintedBlock(from content: String, for ai: AIInstance, command: String) -> String? {
        let cleaned = content.replacingOccurrences(
            of: "\\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])",
            with: "",
            options: .regularExpression
        )
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        guard !lines.isEmpty else { return nil }

        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }

        func isEchoLine(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t == cmd { return true }
            if t.hasSuffix(" \(cmd)") { return true }
            if (t.hasPrefix(">") || t.hasPrefix("›") || t.hasPrefix("$")) && t.contains(cmd) { return true }
            if t.contains("✨") && t.hasSuffix(cmd) { return true } // Kimi: username✨ /cmd
            return false
        }

        func isBackToInputPromptLine(_ line: String) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            let lower = trimmed.lowercased()
            if lower.contains("type your message") { return true }
            if lower.contains("@path/to/file") { return true }
            if lower.contains("context left") { return true }
            // 一些 CLI 会把 “no sandbox / auto” 这类状态条和输入框放在同一行（不是输出内容）
            if lower.contains("no sandbox") && (lower.contains("auto") || lower.contains("workspace")) { return true }
            // Codex 的输入提示符（U+203A），很多情况下会出现在输入行的开头
            if trimmed.hasPrefix("›") && lower.contains("type your message") { return true }
            // Kimi：裸 prompt 行通常是 "<username>✨"
            if trimmed.hasSuffix("✨") && !trimmed.contains(" ") { return true }
            return false
        }

        // 找到最后一次该命令被回显的位置
        var echoIndex: Int? = nil
        for (idx, line) in lines.enumerated().reversed() {
            if isEchoLine(line) {
                echoIndex = idx
                break
            }
        }
        guard let fromIndex = echoIndex else { return nil }

        // 从回显后开始，截取到“回到输入态提示符”为止
        var endIndexExclusive = lines.count
        for idx in (fromIndex + 1)..<lines.count {
            if isBackToInputPromptLine(lines[idx]) {
                endIndexExclusive = idx
                break
            }
        }

        guard endIndexExclusive > fromIndex + 1 else { return nil }
        var block = Array(lines[(fromIndex + 1)..<endIndexExclusive])

        // 去掉尾部空行（保留中间空行以保持表格/分段）
        while let last = block.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            block.removeLast()
        }

        let joined = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    private func collapseMultilineForSingleLineREPL(_ text: String) -> String {
        // 目标：保证最终字符串不包含换行，从而只提交一次输入。
        // 规则：去掉空行，行内 trim，行间用 " | " 分隔，最后压缩多余空白。
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let parts = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let joined = parts.joined(separator: " | ")
        return joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
    
    /// 发送文本到 tmux 会话
    private func sendToSession(_ session: String, text: String) async throws {
        // 对于包含换行的多行文本，使用 tmux buffer 机制确保完整发送
        // 否则 send-keys 会把 \n 当作 Enter 键，导致 prompt 被拆成多次提交
        //
        // ⚠️ 重要：Round2/3 会并发发送多行 prompt 给多个 AI。
        // tmux 的默认（unnamed）buffer 是全局共享的，如果不使用命名 buffer，
        // 并发时会发生 “load-buffer 被覆盖 → paste-buffer 粘贴了别人的 prompt” 的串台问题。
        // 因此这里每次多行发送都使用唯一的命名 buffer，并在粘贴后删除。
        
        if text.contains("\n") {
            // 多行文本：写入临时文件 → load-buffer → paste-buffer
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("battlelm_prompt_\(UUID().uuidString).txt")
            let bufferName = "battlelm_prompt_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            
            do {
                try text.write(to: tempFile, atomically: true, encoding: .utf8)
                
                // 加载到 tmux buffer
                let loadResult = try await runTmux(["load-buffer", "-b", bufferName, tempFile.path])
                if loadResult.exitCode != 0 {
                    let message = loadResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw SessionError.commandFailed(message.isEmpty ? "tmux load-buffer failed" : message)
                }
                
                // 粘贴到目标 session
                // -d: paste 后删除 buffer，避免积累；同时避免后续误用同名 buffer
                let pasteResult = try await runTmux(["paste-buffer", "-d", "-b", bufferName, "-t", session])
                if pasteResult.exitCode != 0 {
                    let message = pasteResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw SessionError.commandFailed(message.isEmpty ? "tmux paste-buffer failed" : message)
                }
                
                // 稍等一下确保文本被粘贴
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                
                // 发送 Enter 键提交
                let enterResult = try await runTmux(["send-keys", "-t", session, "Enter"])
                if enterResult.exitCode != 0 {
                    let message = enterResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    throw SessionError.commandFailed(message.isEmpty ? "tmux send-keys Enter failed" : message)
                }
                
                // 清理临时文件（buffer 已在 paste-buffer -d 中删除）
                try? FileManager.default.removeItem(at: tempFile)
            } catch {
                // 尽力清理：临时文件 + buffer（如果 paste 未执行，buffer 可能仍存在）
                try? FileManager.default.removeItem(at: tempFile)
                _ = try? await runTmux(["delete-buffer", "-b", bufferName])
                throw error
            }
        } else {
            // 单行文本：使用原有的 send-keys -l 方式
            let sendResult = try await runTmux(["send-keys", "-t", session, "-l", text])
            if sendResult.exitCode != 0 {
                let message = sendResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.commandFailed(message.isEmpty ? "tmux send-keys failed" : message)
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            let enterResult = try await runTmux(["send-keys", "-t", session, "Enter"])
            if enterResult.exitCode != 0 {
                let message = enterResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SessionError.commandFailed(message.isEmpty ? "tmux send-keys Enter failed" : message)
            }
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
                await transientState.clearPendingUserMessage(for: ai.id)
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
        await transientState.clearPendingUserMessage(for: ai.id)
    }
    
    /// 传统方式：使用 capture-pane 流式提取响应（用于非 Claude AI 或 fallback）
    private func streamWithCapturPane(from ai: AIInstance,
                                       onUpdate: @escaping (String, Bool, Bool) -> Void,
                                       stableSeconds: Double,
                                       maxWait: Double) async throws {
        let startTime = Date()
        var lastContent = ""
        var lastChangeTime = Date()

        let userMessage = await transientState.pendingUserMessage(for: ai.id)
        
        do {
            while Date().timeIntervalSince(startTime) < maxWait {
                let rawContent = try await captureOutput(from: ai)

                // 若在等待回复期间进入“需要用户确认/选择”的交互态，说明本轮对话无法继续自动推进：
                // - 继续等待会导致 UI 长时间转圈
                // - pendingUserMessage 也无法清理，后续发送会被 busy 阻塞
                //
                // 因此这里直接结束本轮 streaming，并把交互交给 TerminalChoicePromptCard。
                let promptInNormal = detectTerminalChoicePrompt(in: rawContent)
                let promptInAlt: TerminalChoicePrompt?
                if promptInNormal == nil {
                    if let alt = try? await captureAlternateScreen(from: ai) {
                        promptInAlt = detectTerminalChoicePrompt(in: alt)
                    } else {
                        promptInAlt = nil
                    }
                } else {
                    promptInAlt = nil
                }

                if let prompt = promptInNormal ?? promptInAlt {
                    let signature = terminalChoicePromptSignature(prompt)
                    let suppressed = await terminalPromptDismissalState.isRecentlyDismissed(
                        signature: signature,
                        for: ai.id,
                        ttlSeconds: dismissedTerminalPromptTTLSeconds
                    )
                    if !suppressed {
                        await MainActor.run { terminalChoicePrompts[ai.id] = prompt }
                        await MainActor.run { onUpdate("", false, true) }
                        await transientState.clearPendingUserMessage(for: ai.id)
                        return
                    }
                }

                let response = extractResponse(from: rawContent, for: ai, userMessage: userMessage)
                let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

                // “思考/处理中”检测：只看响应尾部，避免工具日志残留导致永远不完成
                let isThinking = !trimmedResponse.isEmpty && isLikelyInProgressResponse(trimmedResponse, for: ai)

                // 检查内容是否变化
                if response != lastContent {
                    lastContent = response
                    lastChangeTime = Date()

                    // 回调更新（未完成）
                    await MainActor.run {
                        onUpdate(response, isThinking, false)
                    }
                } else if !trimmedResponse.isEmpty && !isThinking {
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
        } catch {
            await transientState.clearPendingUserMessage(for: ai.id)
            throw error
        }

        // 超时，返回当前内容（避免一直卡住）
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
                    let response = try await ClaudeTranscriptExtractor.streamLatestResponse(
                        transcriptURL: transcriptURL,
                        afterUserUuid: nil,
                        expectedUserText: nil,
                        minTimestamp: nil,
                        onUpdate: { _, _ in },
                        stableSeconds: stableSeconds,
                        maxWait: maxWait
                    )
                    await transientState.clearPendingUserMessage(for: ai.id)
                    return response
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
        
        // Fallback：传统 capture-pane 方式
        // 关键：不要用“整屏稳定”判定完成；Gemini/Qwen 可能长时间无输出（或只输出工具进度），
        // 这会导致误判完成并提前进入下一轮。
        let startTime = Date()
        var lastResponse = ""
        var lastChangeTime = Date()

        let userMessage = await transientState.pendingUserMessage(for: ai.id)

        do {
            while Date().timeIntervalSince(startTime) < maxWait {
                let content = try await captureOutput(from: ai, lines: 10000)
                let response = extractResponse(from: content, for: ai, userMessage: userMessage)
                let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

                if response != lastResponse {
                    lastResponse = response
                    lastChangeTime = Date()
                } else if !trimmedResponse.isEmpty, !isLikelyInProgressResponse(trimmedResponse, for: ai) {
                    // 响应已开始且不处于“处理中”，检查稳定性
                    if Date().timeIntervalSince(lastChangeTime) >= stableSeconds {
                        await transientState.clearPendingUserMessage(for: ai.id)
                        if !trimmedResponse.isEmpty {
                            let aiEvent = MessageDTO(
                                id: UUID(),
                                senderId: ai.id,
                                senderType: "ai",
                                senderName: ai.name,
                                content: trimmedResponse,
                                timestamp: Date()
                            )
                            broadcastToRemote(aiId: ai.id, message: aiEvent, isStreaming: false)
                        }
                        return response
                    }
                }

                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 秒
            }
        } catch {
            await transientState.clearPendingUserMessage(for: ai.id)
            throw error
        }

        await transientState.clearPendingUserMessage(for: ai.id)
        throw SessionError.timeout
    }

    private func isLikelyInProgressResponse(_ response: String, for ai: AIInstance) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let nonEmptyLines = trimmed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let tail = nonEmptyLines.suffix(3).joined(separator: " ").lowercased()

        // 通用：spinner / 进度符号
        if tail.contains("⁝") { return true }

        switch ai.type {
        case .gemini:
            return tail.contains("searching the web") ||
                tail.contains("search results") ||
                tail.contains("evaluating search") ||
                tail.contains("googlesearch") ||
                (tail.contains("esc") && tail.contains("cancel")) ||
                (tail.contains("press") && tail.contains("cancel"))
        case .qwen, .kimi:
            return tail.contains("thinking") ||
                tail.contains("evaluating") ||
                tail.contains("searching") ||
                (tail.contains("esc") && tail.contains("cancel"))
        case .codex:
            return tail.contains("thinking") ||
                tail.contains("analyzing") ||
                tail.contains("processing")
        case .claude:
            return tail.contains("thinking") ||
                tail.contains("envisioning") ||
                tail.contains("enchanting") ||
                (tail.contains("esc") && tail.contains("interrupt"))
        }
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
        case .qwen:
            userPrefixes = [">"]
            // Qwen：优先使用更“像 TUI 前缀”的符号，避免把用户 prompt 中的普通 Markdown 列表（*）误判为回复起点。
            responsePrefixes = ["+", "•", "✦"]
        case .kimi:
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

        func isGeminiUpdateNoticeLine(_ line: String) -> Bool {
            guard ai.type == .gemini else { return false }
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !lower.isEmpty else { return false }
            if lower.contains("gemini cli update available") { return true }
            if lower.contains("installed via homebrew") { return true }
            let hasBrewUpgrade = lower.contains("brew upgrade")
            if hasBrewUpgrade && (lower.contains("homebrew") || lower.contains("gemini")) { return true }
            if lower.contains("please update") && hasBrewUpgrade { return true }
            return false
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

        // Kimi 的提示符不是 ">"，而是类似 "<username>✨" 的形式；例如：
        // - 用户输入行： "user✨ 1+1?"
        // - 等待输入提示： "user✨"
        // 若只依赖 userPrefixes（">"）会找不到本轮用户输入行，进而永远提取不到回复。
        func kimiPromptPrefixIndex(in line: String) -> String.Index? {
            guard let sparkle = line.firstIndex(of: "✨") else { return nil }
            let before = line[..<sparkle]
            guard !before.isEmpty else { return nil }
            guard !before.contains(where: { $0.isWhitespace }) else { return nil }
            // 用户名通常由字母/数字/._- 组成；这里用于区分普通输出中的 "✨"。
            let allowed: (Character) -> Bool = { ch in
                ch.isLetter || ch.isNumber || ch == "_" || ch == "-" || ch == "."
            }
            guard before.allSatisfy(allowed) else { return nil }
            return sparkle
        }
        func kimiLineContentAfterPrompt(_ line: String) -> String? {
            guard let sparkle = kimiPromptPrefixIndex(in: line) else { return nil }
            let after = line[line.index(after: sparkle)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty ? nil : after
        }
        func isKimiBarePromptLine(_ trimmed: String) -> Bool {
            guard ai.type == .kimi else { return false }
            guard let sparkle = kimiPromptPrefixIndex(in: trimmed) else { return false }
            let after = trimmed[trimmed.index(after: sparkle)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return after.isEmpty
        }

        // Gemini/Qwen/Kimi 等 CLI 会回显用户输入；当输入很长（尤其包含换行）时，
        // 回显经常会被折行成多行，其中只有第一行带提示符（如 ">"），后续折行看起来像“输出”。
        // 这会误导 fallback 把“用户输入回显折行”当成 AI 回复起点，进而导致 waitForResponse 提前完成。
        //
        // 解决：fallback 选择起点时，跳过任何“内容明显来自本轮 userMessage 的折行”。
        // 用一种足够鲁棒的方式忽略空白差异（换行/多空格被折叠）。
        let compactUserMessage: String? = {
            guard let userMessage, !userMessage.isEmpty else { return nil }
            return userMessage
                .lowercased()
                .filter { !$0.isWhitespace }
        }()
        func isLikelyEchoedUserInputContinuation(_ line: String) -> Bool {
            guard let compactUserMessage else { return false }
            let compactLine = line
                .lowercased()
                .filter { !$0.isWhitespace }
            // 太短的行（如 "Qwen:"）既可能是回复也可能是 prompt 片段，不做回显判定。
            guard compactLine.count >= 12 else { return false }
            return compactUserMessage.contains(compactLine)
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

            // Kimi：用户输入行形如 "<username>✨ <message>"，不以 ">" 开头
            if !matched, ai.type == .kimi, let afterPrompt = kimiLineContentAfterPrompt(trimmed) {
                if userLineMatches(afterPrompt, userMessage) {
                    lastUserInputIndex = i
                    matched = true
                }
            }

            if matched {
                break
            }
        }

        // 关键：找不到用户输入行就不要从头扫描（否则会把顶部横幅当成回复，稳定得到空）
        guard let lastUserInputIndex else { return "" }
        let searchStartIndex = lastUserInputIndex + 1
        
        // 第二步：从用户输入之后找响应起始行
        // - Codex/Claude 通常有固定前缀（•/✦/●）
        // - Gemini/Qwen/Kimi 的输出未必以这些符号开头，因此需要 fallback
        var responseStartIndex: Int? = nil

        for i in searchStartIndex..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // 找到以响应前缀开头的行
            for prefix in responsePrefixes where !prefix.isEmpty {
                if trimmed.hasPrefix(prefix) {
                    responseStartIndex = i
                    break
                }
            }

            if responseStartIndex != nil {
                break
            }
        }

        if responseStartIndex == nil, ai.type == .gemini || ai.type == .kimi {
            // Fallback：找“第一条非空、非噪声、非下一轮用户提示符”的输出行作为起点
            let fallbackMetaPatterns = [
                "Using:",
                "Using：",
                "Ask Gemini",
                ".md file",
                "context left",
                "for shortcuts",
                "Type your message",
                "% context",
                "Welcome to Kimi",
                "Send /help",
                "upgrade",
                "New version available"
            ]
            for i in searchStartIndex..<lines.count {
                let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed == "|" { continue }
                if trimmed.contains("Type your message") { continue }
                if trimmed.contains(where: { boxChars.contains($0) }) { continue }
                if isGeminiUpdateNoticeLine(trimmed) { continue }
                if fallbackMetaPatterns.contains(where: { trimmed.contains($0) }) { continue }
                if isLikelyEchoedUserInputContinuation(trimmed) { continue }

                var looksLikeNextUserPrompt = false
                for prefix in userPrefixes where trimmed.hasPrefix(prefix) {
                    looksLikeNextUserPrompt = true
                    break
                }
                if looksLikeNextUserPrompt { continue }

                responseStartIndex = i
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

            // Gemini：CLI 有时会插入“更新提示”横幅；这些不是回复内容，且可能导致 waitForResponse 提前结束。
            // 这里跳过它们（不 break），继续向后收集真正的回复。
            if isGeminiUpdateNoticeLine(trimmed) {
                continue
            }
            
            // 遇到边框字符：
            // - Qwen：会输出“home directory”之类的 box 警告，属于噪声；跳过即可，避免截断回复。
            // - 其他：多见于交互确认/弹窗，保守停止。
            if trimmed.contains(where: { boxChars.contains($0) }) {
                if ai.type == .qwen { continue }
                break
            }
            
            // 停止条件：Kimi 回到主提示符（例如 "user✨"）
            if isKimiBarePromptLine(trimmed) {
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
                if ai.type == .qwen { continue }
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

    private lazy var tmuxExecutableURL: URL? = {
        let candidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        guard let resolved = Self.resolveExecutable(named: "tmux") else {
            return nil
        }
        return URL(fileURLWithPath: resolved)
    }()
    
    @discardableResult
    private func runTmux(_ args: [String]) async throws -> CommandResult {
        // 使用独立 socket (-L battlelm) 隔离用户的 tmux 配置
        guard let tmuxExecutableURL else {
            throw SessionError.commandFailed("tmux not found. Please install tmux (e.g. `brew install tmux`).")
        }
        return try await runProcess(
            executableURL: tmuxExecutableURL,
            arguments: ["-L", tmuxSocket] + args
        )
    }
    
    private func runShellCommand(_ command: String) async throws -> CommandResult {
        return try await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", command]
        )
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            let resumeQueue = DispatchQueue(label: "battlelm.sessionmanager.runProcess.resumeOnce")
            var didResume = false

            let dataQueue = DispatchQueue(label: "battlelm.sessionmanager.runProcess.data")
            var stdoutData = Data()
            var stderrData = Data()

            @Sendable func resumeOnce(_ result: Result<CommandResult, Error>) {
                let shouldResume: Bool = resumeQueue.sync {
                    if didResume { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            task.executableURL = executableURL
            task.arguments = arguments
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            task.environment = environment

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                dataQueue.sync {
                    stdoutData.append(chunk)
                }
            }

            stderrHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                dataQueue.sync {
                    stderrData.append(chunk)
                }
            }

            task.terminationHandler = { _ in
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil

                let remainingOut = stdoutHandle.readDataToEndOfFile()
                let remainingErr = stderrHandle.readDataToEndOfFile()

                let result: CommandResult = dataQueue.sync {
                    stdoutData.append(remainingOut)
                    stderrData.append(remainingErr)
                    return CommandResult(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
                        exitCode: task.terminationStatus
                    )
                }

                resumeOnce(.success(result))
            }

            do {
                try task.run()
            } catch {
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                resumeOnce(.failure(error))
            }
        }
    }

    private static func resolveExecutable(named name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let pathValue = env["PATH"], !pathValue.isEmpty else { return nil }

        for directory in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
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
    case busy(String)
    case timeout
    case commandFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .sessionNotFound(let name):
            return "Session not found for \(name)"
        case .userActionRequired(let message):
            return message
        case .busy(let message):
            return message
        case .timeout:
            return "Waiting for response timed out"
        case .commandFailed(let message):
            return "Command failed: \(message)"
        }
    }
}
