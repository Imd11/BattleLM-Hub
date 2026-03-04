// BattleLM/Services/AIStreamEngine.swift
// JSON Stream Engine — 绕过 tmux，直接消费 CLI 的结构化输出
//
// 当前默认路径：Claude/Codex/Gemini/Qwen 走 headless JSON 流。
// 不支持的 AI 类型 / slash command / JSONStream 失败时，自动 fallback 到 LegacyTmuxEngine。

import Foundation
import Combine

// MARK: - Protocol

/// 统一的 AI 消息引擎接口。
/// `LegacyTmuxEngine` 包装 SessionManager（旧路径），`JSONStreamEngine` 直接 spawn 进程。
protocol AIStreamEngine {
    func startSession(for ai: AIInstance) async throws
    func stopSession(for ai: AIInstance) async throws
    func sendMessage(_ message: String, to ai: AIInstance) async throws
    func waitForResponse(from ai: AIInstance,
                         stableSeconds: Double,
                         maxWait: Double) async throws -> String
    func streamResponse(from ai: AIInstance,
                        onUpdate: @escaping (String, Bool, Bool) -> Void,
                        stableSeconds: Double,
                        maxWait: Double) async throws
    func sendEscapeToSessions(for aiIds: Set<UUID>?) async
    func clearPendingMessages(for aiIds: Set<UUID>) async
}

// MARK: - Legacy Tmux Engine (旧路径包装，零行为变更)

/// 直接委托给 `SessionManager.shared`，与重构前行为完全一致。
struct LegacyTmuxEngine: AIStreamEngine {
    private let sm = SessionManager.shared

    func startSession(for ai: AIInstance) async throws {
        try await sm.startSession(for: ai)
    }

    func stopSession(for ai: AIInstance) async throws {
        try await sm.stopSession(for: ai)
    }

    func sendMessage(_ message: String, to ai: AIInstance) async throws {
        try await sm.sendMessage(message, to: ai)
    }

    func waitForResponse(from ai: AIInstance,
                         stableSeconds: Double = 3.0,
                         maxWait: Double = 60.0) async throws -> String {
        try await sm.waitForResponse(from: ai, stableSeconds: stableSeconds, maxWait: maxWait)
    }

    func streamResponse(from ai: AIInstance,
                        onUpdate: @escaping (String, Bool, Bool) -> Void,
                        stableSeconds: Double = 4.0,
                        maxWait: Double = 120.0) async throws {
        try await sm.streamResponse(from: ai, onUpdate: onUpdate, stableSeconds: stableSeconds, maxWait: maxWait)
    }

    func sendEscapeToSessions(for aiIds: Set<UUID>?) async {
        await sm.sendEscapeToSessions(for: aiIds)
    }

    func clearPendingMessages(for aiIds: Set<UUID>) async {
        await sm.clearPendingMessages(for: aiIds)
    }
}

// MARK: - JSON Stream Engine (新路径)

/// 对支持 JSON 流的 CLI（Phase 1: 仅 Claude），直接 spawn 进程 + 消费 NDJSON stdout。
/// 不支持的 AI 类型自动委托给 `LegacyTmuxEngine`。
class JSONStreamEngine: AIStreamEngine {
    static let shared = JSONStreamEngine()

    private let fallback = LegacyTmuxEngine()

    /// 正在运行的 headless 进程 [AI ID: Process]
    private var activeProcesses: [UUID: Process] = [:]
    /// Headless 模式下的待发消息 [AI ID: Message]
    private var pendingMessages: [UUID: String] = [:]
    private let lock = NSLock()

    private init() {}

    // MARK: - Routing

    /// Headless 模式支持：Claude/Qwen (SDK bridge), Gemini CLI, Codex CLI
    /// Kimi 暂不支持（v0.53 为 Python CLI，与 Node.js SDK 不兼容）。
    /// 不需要 tmux，直接 spawn CLI 进程 + 解析 JSONL 输出。
    private func supportsHeadless(_ ai: AIInstance) -> Bool {
        switch ai.type {
        case .claude, .gemini, .codex, .qwen:
            return true
        default:
            return false
        }
    }

    /// 当 headless 失败需要 fallback 到 tmux 时，懒启动 tmux 会话。
    private func ensureTmuxFallback(for ai: AIInstance) async throws {
        let sessionName = await MainActor.run { SessionManager.shared.activeSessions[ai.id] }
        if sessionName == nil || sessionName == "__headless__" {
            await SessionManager.shared.unregisterHeadlessSession(for: ai)
            print("🔄 Lazy-starting tmux session for \(ai.name) (fallback)")
            try await fallback.startSession(for: ai)
        }
    }

    // MARK: - Session Lifecycle

    func startSession(for ai: AIInstance) async throws {
        if supportsHeadless(ai) {
            // ⚡ Headless 模式：不启动 tmux，只注册 UI 状态（绿点亮起）
            await SessionManager.shared.registerHeadlessSession(for: ai)
        } else {
            try await fallback.startSession(for: ai)
        }
    }

    func stopSession(for ai: AIInstance) async throws {
        cancelProcess(for: ai.id)
        let sessionName = await MainActor.run { SessionManager.shared.activeSessions[ai.id] }
        if sessionName == "__headless__" {
            await SessionManager.shared.unregisterHeadlessSession(for: ai)
        } else {
            try await fallback.stopSession(for: ai)
        }
    }

    func sendEscapeToSessions(for aiIds: Set<UUID>?) async {
        let targets = aiIds ?? Set(lock.withLock { activeProcesses.keys })
        for id in targets {
            cancelProcess(for: id)
        }
        await fallback.sendEscapeToSessions(for: aiIds)
    }

    func clearPendingMessages(for aiIds: Set<UUID>) async {
        await fallback.clearPendingMessages(for: aiIds)
    }

    // MARK: - Send + Stream (核心路径)

    func sendMessage(_ message: String, to ai: AIInstance) async throws {
        if supportsHeadless(ai) {
            lock.withLock { pendingMessages[ai.id] = message }
            return
        }
        try await fallback.sendMessage(message, to: ai)
    }

    func waitForResponse(from ai: AIInstance,
                         stableSeconds: Double = 3.0,
                         maxWait: Double = 60.0) async throws -> String {
        guard supportsHeadless(ai) else {
            return try await fallback.waitForResponse(from: ai, stableSeconds: stableSeconds, maxWait: maxWait)
        }

        let message = lock.withLock { pendingMessages.removeValue(forKey: ai.id) }
        guard let message else {
            print("⚠️ JSONStreamEngine: no pending message for \(ai.name), falling back to tmux")
            try await ensureTmuxFallback(for: ai)
            return try await fallback.waitForResponse(from: ai, stableSeconds: stableSeconds, maxWait: maxWait)
        }

        do {
            let startTime = Date()
            var result = ""
            try await spawnAndStream(message: message, ai: ai, maxWait: maxWait) { content, _, isComplete in
                result = content
            }
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ JSONStreamEngine waitForResponse completed in \(String(format: "%.1f", elapsed))s for \(ai.name)")
            return result
        } catch {
            print("⚠️ JSONStreamEngine failed for \(ai.name): \(error)")
            throw error
        }
    }

    func streamResponse(from ai: AIInstance,
                        onUpdate: @escaping (String, Bool, Bool) -> Void,
                        stableSeconds: Double = 4.0,
                        maxWait: Double = 120.0) async throws {
        guard supportsHeadless(ai) else {
            try await fallback.streamResponse(from: ai, onUpdate: onUpdate, stableSeconds: stableSeconds, maxWait: maxWait)
            return
        }

        let message = lock.withLock { pendingMessages.removeValue(forKey: ai.id) }
        guard let message else {
            print("⚠️ JSONStreamEngine: no pending message for \(ai.name), falling back to tmux")
            try await ensureTmuxFallback(for: ai)
            try await fallback.streamResponse(from: ai, onUpdate: onUpdate, stableSeconds: stableSeconds, maxWait: maxWait)
            return
        }

        do {
            let startTime = Date()
            try await spawnAndStream(message: message, ai: ai, maxWait: maxWait, onUpdate: onUpdate)
            let elapsed = Date().timeIntervalSince(startTime)
            print("✅ JSONStreamEngine streamResponse completed in \(String(format: "%.1f", elapsed))s for \(ai.name)")
        } catch {
            print("⚠️ JSONStreamEngine failed for \(ai.name): \(error)")
            DispatchQueue.main.async {
                onUpdate("Error: \(error.localizedDescription)", false, true)
            }
        }
    }

    // MARK: - Core: Spawn Process + Parse NDJSON

    /// 统一的 headless 流式入口：根据 AI 类型分发到对应的 CLI 实现。
    private func spawnAndStream(message: String,
                                ai: AIInstance,
                                maxWait: Double,
                                onUpdate: @escaping (String, Bool, Bool) -> Void) async throws {
        switch ai.type {
        case .claude:
            try await spawnBridgeProcess(message: message, ai: ai, maxWait: maxWait, onUpdate: onUpdate,
                                         bridgeScript: "claude-bridge.mjs")
        case .qwen:
            try await spawnBridgeProcess(message: message, ai: ai, maxWait: maxWait, onUpdate: onUpdate,
                                         bridgeScript: "qwen-bridge.mjs")
        case .gemini:
            try await spawnCLIDirect(message: message, ai: ai, maxWait: maxWait, onUpdate: onUpdate,
                                     cliName: "gemini",
                                     buildArgs: Self.geminiArgs(message: message, model: ai.effectiveModel))
        case .codex:
            try await spawnBridgeProcess(message: message, ai: ai, maxWait: maxWait, onUpdate: onUpdate,
                                         bridgeScript: "codex-bridge.mjs")
        default:
            throw SessionError.commandFailed("\(ai.type) does not support headless mode")
        }
    }

    // MARK: - CLI Args Builders

    private static func geminiArgs(message: String, model: String) -> [String] {
        // gemini "query" --model <model> --output-format stream-json --sandbox false --yolo
        var args = [message, "--output-format", "stream-json", "--sandbox", "false", "--yolo"]
        if !model.isEmpty {
            args += ["--model", model]
        }
        return args
    }

    private static func codexArgs(message: String) -> [String] {
        // codex exec "query" --json --full-auto --skip-git-repo-check
        return ["exec", message, "--json", "--full-auto", "--skip-git-repo-check"]
    }

    // MARK: - Claude SDK Bridge (Node.js)

    /// 通过 Node.js bridge 调用 @anthropic-ai/claude-agent-sdk。
    private func spawnBridgeProcess(message: String,
                                    ai: AIInstance,
                                    maxWait: Double,
                                    onUpdate: @escaping (String, Bool, Bool) -> Void,
                                    bridgeScript: String) async throws {
        let bridgePath = Self.bridgeScriptPath(named: bridgeScript)
        let workDir = ai.workingDirectory.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : ai.workingDirectory

        guard FileManager.default.fileExists(atPath: bridgePath) else {
            throw SessionError.commandFailed("\(bridgeScript) not found at \(bridgePath)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")

        let bridgeDir = (bridgePath as NSString).deletingLastPathComponent
        let shellCmd = "export NODE_PATH=\"\(bridgeDir)/node_modules\"; exec node \"\(bridgePath)\""
        proc.arguments = ["-lc", shellCmd]
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        registerProcess(proc, for: ai.id)

        let firstTokenTime = Date()
        var accumulatedText = ""
        var receivedFirstToken = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var buffer = ""
            var didResume = false
            let resumeLock = NSLock()

            func resumeOnce(_ result: Result<Void, Error>) {
                let shouldResume = resumeLock.withLock {
                    if didResume { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                buffer += String(data: data, encoding: .utf8) ?? ""

                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])

                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty else { continue }

                    if let parsed = Self.parseBridgeEvent(trimmedLine) {
                        switch parsed {
                        case .textDelta(let text):
                            accumulatedText += text
                            if !receivedFirstToken {
                                receivedFirstToken = true
                                let latency = Date().timeIntervalSince(firstTokenTime)
                                print("⚡ AgentSDK first token in \(String(format: "%.0f", latency * 1000))ms for \(ai.name)")
                            }
                            DispatchQueue.main.async {
                                onUpdate(accumulatedText, false, false)
                            }

                        case .done:
                            DispatchQueue.main.async {
                                onUpdate(accumulatedText, false, true)
                            }
                            handle.readabilityHandler = nil
                            resumeOnce(.success(()))

                        case .error(let msg):
                            // 如果已经有文本输出，追加错误信息但不 fail
                            if !accumulatedText.isEmpty {
                                accumulatedText += "\n\n⚠️ \(msg)"
                                DispatchQueue.main.async {
                                    onUpdate(accumulatedText, false, true)
                                }
                                handle.readabilityHandler = nil
                                resumeOnce(.success(()))
                            } else {
                                handle.readabilityHandler = nil
                                resumeOnce(.failure(SessionError.commandFailed(msg)))
                            }

                        case .ignored:
                            break
                        }
                    }
                }
            }

            proc.terminationHandler = { [weak self] process in
                self?.unregisterProcess(for: ai.id)
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus != 0 && !receivedFirstToken {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    let errorMsg = stderrText.prefix(300).isEmpty
                        ? "Claude 响应超时，请重试"
                        : String(stderrText.prefix(300))
                    resumeOnce(.failure(SessionError.commandFailed(errorMsg)))
                } else {
                    // done 事件已在 readabilityHandler 中发送了 onUpdate(isFinal=true)
                    // 不再重复发送，否则 UI 会创建两个消息气泡
                    resumeOnce(.success(()))
                }
            }

            do {
                try proc.run()

                // 向 bridge 发送 JSON 请求，然后关闭 stdin
                var request: [String: Any] = [
                    "prompt": message,
                    "cwd": workDir,
                    "model": ai.effectiveModel
                ]
                if let effort = ai.effectiveEffort {
                    request["reasoningEffort"] = effort.rawValue
                }
                if ai.thinkingEnabled {
                    request["thinkingEnabled"] = true
                }
                if let jsonData = try? JSONSerialization.data(withJSONObject: request),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    stdinPipe.fileHandleForWriting.write((jsonStr + "\n").data(using: .utf8)!)
                }
                stdinPipe.fileHandleForWriting.closeFile()

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maxWait) {
                    let shouldTimeout = resumeLock.withLock { !didResume }
                    guard shouldTimeout else { return }
                    print("⏱️ AgentSDK timeout after \(maxWait)s for \(ai.name)")
                    if proc.isRunning { proc.terminate() }
                    // 总是通知 UI 结束, 防止无限转圈
                    DispatchQueue.main.async {
                        let text = accumulatedText.isEmpty
                            ? "⚠️ Claude 响应超时（\(Int(maxWait))秒），请重试。"
                            : accumulatedText
                        onUpdate(text, false, true)
                    }
                    resumeOnce(.success(()))
                }
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    // MARK: - Gemini / Codex: Direct CLI Spawn

    /// 直接 spawn Gemini CLI 或 Codex CLI，解析 JSONL 输出。
    /// 不需要 Node.js bridge，CLI 本身支持 --output-format stream-json / --json。
    private func spawnCLIDirect(message: String,
                                ai: AIInstance,
                                maxWait: Double,
                                onUpdate: @escaping (String, Bool, Bool) -> Void,
                                cliName: String,
                                buildArgs: [String]) async throws {
        let workDir = ai.workingDirectory.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.path
            : ai.workingDirectory

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 用 login shell 继承完整 PATH，然后 exec CLI
        let argsStr = buildArgs.map { escapeShellArg($0) }.joined(separator: " ")
        proc.arguments = ["-lc", "exec \(cliName) \(argsStr)"]
        proc.currentDirectoryURL = URL(fileURLWithPath: workDir)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        registerProcess(proc, for: ai.id)

        let firstTokenTime = Date()
        var accumulatedText = ""
        var receivedFirstToken = false
        let isGemini = (ai.type == .gemini)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var buffer = ""
            var didResume = false
            let resumeLock = NSLock()

            func resumeOnce(_ result: Result<Void, Error>) {
                let shouldResume = resumeLock.withLock {
                    if didResume { return false }
                    didResume = true
                    return true
                }
                guard shouldResume else { return }
                continuation.resume(with: result)
            }

            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }

                buffer += String(data: data, encoding: .utf8) ?? ""

                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newlineRange.lowerBound])
                    buffer = String(buffer[newlineRange.upperBound...])

                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty else { continue }

                    if let parsed = isGemini
                        ? JSONStreamEngine.parseGeminiEvent(trimmedLine)
                        : JSONStreamEngine.parseCodexEvent(trimmedLine) {
                        switch parsed {
                        case .textDelta(let text):
                            accumulatedText += text
                            if !receivedFirstToken {
                                receivedFirstToken = true
                                let latency = Date().timeIntervalSince(firstTokenTime)
                                print("⚡ \(cliName) first token in \(String(format: "%.0f", latency * 1000))ms for \(ai.name)")
                            }
                            DispatchQueue.main.async {
                                onUpdate(accumulatedText, false, false)
                            }

                        case .done:
                            DispatchQueue.main.async {
                                onUpdate(accumulatedText, false, true)
                            }
                            handle.readabilityHandler = nil
                            resumeOnce(.success(()))

                        case .error(let msg):
                            if !accumulatedText.isEmpty {
                                accumulatedText += "\n\n⚠️ \(msg)"
                                DispatchQueue.main.async {
                                    onUpdate(accumulatedText, false, true)
                                }
                                handle.readabilityHandler = nil
                                resumeOnce(.success(()))
                            } else {
                                handle.readabilityHandler = nil
                                resumeOnce(.failure(SessionError.commandFailed(msg)))
                            }

                        case .ignored:
                            break
                        }
                    }
                }
            }

            proc.terminationHandler = { [weak self] process in
                self?.unregisterProcess(for: ai.id)
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus != 0 && !receivedFirstToken {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
                    let errorMsg = stderrText.prefix(300).isEmpty
                        ? "\(cliName) 响应超时，请重试"
                        : String(stderrText.prefix(300))
                    resumeOnce(.failure(SessionError.commandFailed(errorMsg)))
                } else {
                    resumeOnce(.success(()))
                }
            }

            do {
                try proc.run()

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maxWait) {
                    let shouldTimeout = resumeLock.withLock { !didResume }
                    guard shouldTimeout else { return }
                    print("⏱️ \(cliName) timeout after \(maxWait)s for \(ai.name)")
                    if proc.isRunning { proc.terminate() }
                    DispatchQueue.main.async {
                        let text = accumulatedText.isEmpty
                            ? "⚠️ \(cliName) 响应超时（\(Int(maxWait))秒），请重试。"
                            : accumulatedText
                        onUpdate(text, false, true)
                    }
                    resumeOnce(.success(()))
                }
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    // MARK: - Event Parsers

    private enum BridgeEventType {
        case textDelta(String)
        case done
        case error(String)
        case ignored
    }

    /// 解析 claude-bridge.mjs 输出的简化 JSON 事件
    private static func parseBridgeEvent(_ jsonLine: String) -> BridgeEventType? {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }

        switch type {
        case "text":
            if let content = obj["content"] as? String, !content.isEmpty {
                return .textDelta(content)
            }
            return .ignored

        case "text_delta":
            if let content = obj["content"] as? String, !content.isEmpty {
                return .textDelta(content)
            }
            return .ignored

        case "thinking", "thinking_delta":
            return .ignored

        case "tool_use":
            if let name = obj["name"] as? String {
                print("🔧 Tool use: \(name)")
            }
            return .ignored

        case "tool_result":
            return .ignored

        case "session_init":
            if let sid = obj["sessionId"] as? String {
                print("🔑 Session: \(sid)")
            }
            return .ignored

        case "result":
            return .ignored

        case "done":
            return .done

        case "error":
            let msg = obj["content"] as? String ?? "unknown error"
            return .error(msg)

        default:
            return .ignored
        }
    }

    /// 解析 Gemini CLI --output-format stream-json 事件
    /// 格式: {"type":"init","session_id":"...","model":"auto"}
    ///       {"type":"message","role":"assistant","content":"...","delta":true}
    ///       {"type":"result","status":"success","stats":{...}}
    private static func parseGeminiEvent(_ jsonLine: String) -> BridgeEventType? {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }

        switch type {
        case "init":
            if let sid = obj["session_id"] as? String {
                print("🔑 Gemini session: \(sid)")
            }
            return .ignored

        case "message":
            let role = obj["role"] as? String ?? ""
            if role == "assistant", let content = obj["content"] as? String, !content.isEmpty {
                let isDelta = obj["delta"] as? Bool ?? false
                if isDelta {
                    return .textDelta(content)
                } else {
                    // 非 delta 的 assistant 消息是完整消息，
                    // 但如果之前已有 delta 则不重复
                    return .textDelta(content)
                }
            }
            return .ignored

        case "result":
            let status = obj["status"] as? String ?? ""
            if status == "error" {
                return .error("Gemini error")
            }
            // result 事件标志结束
            return .done

        case "error":
            let msg = obj["message"] as? String ?? obj["content"] as? String ?? "Gemini error"
            return .error(msg)

        default:
            return .ignored
        }
    }

    /// 解析 Codex CLI --json 事件
    /// 格式: {"type":"thread.started",...}
    ///       {"type":"item.text","content":"..."}
    ///       {"type":"turn.completed",...}
    private static func parseCodexEvent(_ jsonLine: String) -> BridgeEventType? {
        guard let data = jsonLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            return nil
        }

        switch type {
        case "message.delta":
            // 流式增量文本
            if let content = obj["content"] as? String, !content.isEmpty {
                return .textDelta(content)
            }
            // 嵌套的 delta 结构
            if let delta = obj["delta"] as? [String: Any],
               let text = delta["text"] as? String, !text.isEmpty {
                return .textDelta(text)
            }
            return .ignored

        case "message.completed":
            if let content = obj["content"] as? String, !content.isEmpty {
                return .textDelta(content)
            }
            return .done

        case "response.completed":
            return .done

        case "error":
            let msg = obj["message"] as? String ?? "Codex error"
            return .error(msg)

        default:
            // Codex 有很多事件类型 (thread.started, turn.started 等), 都忽略
            return .ignored
        }
    }

    // MARK: - Bridge Script Path

    /// 获取 bridge 脚本路径。
    /// 优先使用项目根目录 bridge/，其次 app bundle。
    private static func bridgeScriptPath(named script: String = "claude-bridge.mjs") -> String {
        let baseName = (script as NSString).deletingPathExtension
        let ext = (script as NSString).pathExtension
        // 1. 开发时使用 SRCROOT/bridge/ 或硬编码路径
        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            let devPath = srcRoot + "/bridge/" + script
            if FileManager.default.fileExists(atPath: devPath) { return devPath }
        }
        // 2. 硬编码开发路径（方便调试）
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let fallback = homeDir + "/Desktop/GitHub/BattleLM/bridge/" + script
        if FileManager.default.fileExists(atPath: fallback) { return fallback }
        // 3. app bundle 中的
        if let bundled = Bundle.main.path(forResource: baseName, ofType: ext, inDirectory: "bridge") {
            return bundled
        }
        return fallback
    }

    /// 查找 node 可执行文件
    private static func resolveNodePath() -> String {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            ProcessInfo.processInfo.environment["HOME"].map { $0 + "/.nvm/versions/node" } ?? "",
        ]
        // 先用 which 查找
        let proc = Process()
        let pipe = Pipe()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "command -v node"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && proc.terminationStatus == 0 {
                return path
            }
        } catch {}
        // 兜底
        for c in candidates {
            if FileManager.default.fileExists(atPath: c) { return c }
        }
        return "/usr/local/bin/node"
    }

    // MARK: - Utilities

    private func escapeShellArg(_ arg: String) -> String {
        "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Process Management

    private func registerProcess(_ proc: Process, for aiId: UUID) {
        lock.withLock { activeProcesses[aiId] = proc }
    }

    private func unregisterProcess(for aiId: UUID) {
        lock.withLock { _ = activeProcesses.removeValue(forKey: aiId) }
    }

    private func cancelProcess(for aiId: UUID) {
        lock.withLock {
            if let proc = activeProcesses[aiId], proc.isRunning {
                proc.terminate()
            }
            activeProcesses.removeValue(forKey: aiId)
        }
    }
}

// MARK: - Engine Router

/// 全局路由：固定走 JSONStreamEngine（默认管道）。
enum AIStreamEngineRouter {
    static var active: any AIStreamEngine {
        JSONStreamEngine.shared
    }
}
