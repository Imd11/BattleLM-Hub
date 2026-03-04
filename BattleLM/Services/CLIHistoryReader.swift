// BattleLM/Services/CLIHistoryReader.swift
// Reads local CLI conversation history for Claude Code, Codex, and Gemini CLI.
//
// cc-switch 方式：直接扫描各 CLI 的本地 session 文件目录。
// - Claude: ~/.claude/projects/<encoded-path>/<session-uuid>.jsonl
// - Codex:  ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<session-id>.jsonl
// - Gemini: ~/.gemini/tmp/<hash>/chats/session-*.json
// - Qwen:   ~/.qwen/projects/<encoded-path>/chats/<session-uuid>.jsonl

import Foundation

/// Reads CLI history from local files and provides structured data for UI.
class CLIHistoryReader {
    static let shared = CLIHistoryReader()
    private init() {}

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let fm = FileManager.default

    // MARK: - Public API

    /// Read merged history from all installed CLIs, sorted by timestamp (newest first).
    func readAllHistory(limit: Int = 200) -> [CLIHistoryEntry] {
        var all: [CLIHistoryEntry] = []
        all.append(contentsOf: readClaudeSessions(limit: limit))
        all.append(contentsOf: readCodexSessions(limit: limit))
        all.append(contentsOf: readGeminiSessions(limit: limit))
        all.append(contentsOf: readQwenSessions(limit: limit))
        return all
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    /// Read full conversation from a session file.
    func readConversation(entry: CLIHistoryEntry) -> [CLIConversationMessage] {
        switch entry.cliType {
        case .claude:
            return parseClaudeTranscript(at: entry.project)
        case .codex:
            return parseCodexTranscript(at: entry.project)
        case .gemini:
            return parseGeminiSession(at: entry.project)
        case .qwen:
            return parseQwenTranscript(at: entry.project)
        default:
            return []
        }
    }

    /// Group entries by date for UI display.
    func groupByDate(_ entries: [CLIHistoryEntry]) -> [CLIHistoryGroup] {
        let calendar = Calendar.current
        let now = Date()

        var today: [CLIHistoryEntry] = []
        var yesterday: [CLIHistoryEntry] = []
        var thisWeek: [CLIHistoryEntry] = []
        var earlier: [CLIHistoryEntry] = []

        for entry in entries {
            if calendar.isDateInToday(entry.timestamp) {
                today.append(entry)
            } else if calendar.isDateInYesterday(entry.timestamp) {
                yesterday.append(entry)
            } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                      entry.timestamp > weekAgo {
                thisWeek.append(entry)
            } else {
                earlier.append(entry)
            }
        }

        var groups: [CLIHistoryGroup] = []
        if !today.isEmpty { groups.append(CLIHistoryGroup(id: "today", label: "Today", entries: today)) }
        if !yesterday.isEmpty { groups.append(CLIHistoryGroup(id: "yesterday", label: "Yesterday", entries: yesterday)) }
        if !thisWeek.isEmpty { groups.append(CLIHistoryGroup(id: "week", label: "This Week", entries: thisWeek)) }
        if !earlier.isEmpty { groups.append(CLIHistoryGroup(id: "earlier", label: "Earlier", entries: earlier)) }
        return groups
    }

    // MARK: - Claude: ~/.claude/projects/<path>/<session>.jsonl

    func readClaudeSessions(limit: Int = 100) -> [CLIHistoryEntry] {
        let projectsDir = home.appendingPathComponent(".claude/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return [] }

        var sessions: [CLIHistoryEntry] = []

        for projDir in projectDirs {
            let projPath = projectsDir.appendingPathComponent(projDir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projPath.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: projPath.path) else { continue }

            for file in files {
                guard file.hasSuffix(".jsonl"), !file.hasPrefix("agent-") else { continue }
                let filePath = projPath.appendingPathComponent(file)
                let sessionId = String(file.dropLast(6))

                guard let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let displayText = readFirstClaudeUserMessage(from: filePath.path) ?? sessionId

                sessions.append(CLIHistoryEntry(
                    id: sessionId, cliType: .claude,
                    displayText: displayText, timestamp: modDate,
                    project: filePath.path
                ))
            }
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { $0 }
    }

    private func readFirstClaudeUserMessage(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 8192)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "user",
                  let message = json["message"] as? [String: Any] else { continue }

            let rawContent = message["content"]

            // Case 1: content is a plain string
            if let t = rawContent as? String, !t.isEmpty {
                return String(t.prefix(80))
            }
            // Case 2: content is array of blocks
            if let blocks = rawContent as? [[String: Any]] {
                for block in blocks where block["type"] as? String == "text" {
                    if let t = block["text"] as? String, !t.isEmpty {
                        return String(t.prefix(80))
                    }
                }
            }
        }
        return nil
    }

    private func parseClaudeTranscript(at path: String) -> [CLIConversationMessage] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var messages: [CLIConversationMessage] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            let uuid = json["uuid"] as? String ?? UUID().uuidString

            switch type {
            case "user":
                guard let message = json["message"] as? [String: Any] else { continue }
                let rawContent = message["content"]

                // Case 1: content is a plain string (most common for user input)
                if let text = rawContent as? String, !text.isEmpty {
                    messages.append(CLIConversationMessage(
                        id: uuid, role: .user, content: text,
                        thinking: nil, toolName: nil, timestamp: nil
                    ))
                }
                // Case 2: content is an array of blocks
                else if let blocks = rawContent as? [[String: Any]] {
                    var userText = ""
                    for block in blocks {
                        let blockType = block["type"] as? String ?? ""
                        if blockType == "text" {
                            userText += block["text"] as? String ?? ""
                        }
                        // tool_result blocks are shown as tool output in cc-switch
                        if blockType == "tool_result" {
                            if let resultContent = block["content"] as? String, !resultContent.isEmpty {
                                messages.append(CLIConversationMessage(
                                    id: UUID().uuidString, role: .tool,
                                    content: String(resultContent.prefix(2000)),
                                    thinking: nil, toolName: nil, timestamp: nil
                                ))
                            } else if let resultBlocks = block["content"] as? [[String: Any]] {
                                let text = resultBlocks
                                    .compactMap { $0["text"] as? String }
                                    .joined(separator: "\n")
                                if !text.isEmpty {
                                    messages.append(CLIConversationMessage(
                                        id: UUID().uuidString, role: .tool,
                                        content: String(text.prefix(2000)),
                                        thinking: nil, toolName: nil, timestamp: nil
                                    ))
                                }
                            }
                        }
                    }
                    if !userText.isEmpty {
                        messages.append(CLIConversationMessage(
                            id: uuid, role: .user, content: userText,
                            thinking: nil, toolName: nil, timestamp: nil
                        ))
                    }
                }

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }

                var text = ""
                var thinking: String?

                for block in blocks {
                    let blockType = block["type"] as? String ?? ""
                    switch blockType {
                    case "text":
                        text += block["text"] as? String ?? ""
                    case "thinking":
                        thinking = block["thinking"] as? String
                    case "tool_use":
                        // Emit any accumulated text first
                        if !text.isEmpty {
                            messages.append(CLIConversationMessage(
                                id: UUID().uuidString, role: .assistant, content: text,
                                thinking: thinking, toolName: nil, timestamp: nil
                            ))
                            text = ""
                            thinking = nil
                        }
                        // Emit tool_use as separate message
                        let toolName = block["name"] as? String ?? "tool"
                        messages.append(CLIConversationMessage(
                            id: UUID().uuidString, role: .assistant, content: "",
                            thinking: nil, toolName: toolName, timestamp: nil
                        ))
                    default:
                        break
                    }
                }

                // Emit remaining text
                if !text.isEmpty {
                    messages.append(CLIConversationMessage(
                        id: uuid, role: .assistant, content: text,
                        thinking: thinking, toolName: nil, timestamp: nil
                    ))
                }

            case "summary":
                if let summary = json["summary"] as? String, !summary.isEmpty {
                    messages.append(CLIConversationMessage(
                        id: uuid, role: .assistant, content: summary,
                        thinking: nil, toolName: nil, timestamp: nil
                    ))
                }

            default: break
            }
        }
        return messages
    }

    // MARK: - Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl

    func readCodexSessions(limit: Int = 100) -> [CLIHistoryEntry] {
        let sessionsDir = home.appendingPathComponent(".codex/sessions")
        guard fm.fileExists(atPath: sessionsDir.path) else { return [] }

        var sessions: [CLIHistoryEntry] = []

        // Recursively find all rollout-*.jsonl files
        guard let enumerator = fm.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  url.lastPathComponent.hasPrefix("rollout-") else { continue }

            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast

            // Extract session ID from filename: rollout-2026-03-01T13-36-47-<session-id>.jsonl
            let filename = url.deletingPathExtension().lastPathComponent // "rollout-2026-03-01T13-36-47-<id>"
            let sessionId = extractCodexSessionId(from: filename)

            // Read first user message + project from session_meta
            let (displayText, cwd) = readCodexSessionMeta(from: url.path)

            sessions.append(CLIHistoryEntry(
                id: sessionId, cliType: .codex,
                displayText: displayText ?? sessionId,
                timestamp: modDate,
                project: url.path  // full path for readConversation
            ))
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { $0 }
    }

    /// Extract session ID from Codex filename.
    /// `rollout-2026-03-01T13-36-47-019ca7e6-3301-7850-b658-341628efa4e0` → session ID
    private func extractCodexSessionId(from filename: String) -> String {
        // Format: rollout-YYYY-MM-DDTHH-MM-SS-<uuid>
        // The UUID is the last 36 chars (with hyphens)
        let parts = filename.components(separatedBy: "-")
        // UUID is typically the last 5 parts joined with hyphens
        if parts.count >= 5 {
            let uuidParts = parts.suffix(5)
            return uuidParts.joined(separator: "-")
        }
        return filename
    }

    /// Read the session_meta line and first user message from a Codex JSONL.
    private func readCodexSessionMeta(from path: String) -> (displayText: String?, cwd: String?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 16384) // Codex files have large system prompts
        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var cwd: String?
        var firstUserText: String?

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String ?? ""

            if type == "session_meta" {
                if let payload = json["payload"] as? [String: Any] {
                    cwd = payload["cwd"] as? String
                }
            }

            // User messages in Codex: type=response_item, role=user
            if type == "response_item",
               let payload = json["payload"] as? [String: Any],
               payload["role"] as? String == "user",
               let content = payload["content"] as? [[String: Any]] {

                for block in content where block["type"] as? String == "input_text" {
                    if let t = block["text"] as? String,
                       !t.isEmpty,
                       !t.hasPrefix("<"),  // Skip XML-wrapped system prompts
                       !t.hasPrefix("#") { // Skip AGENTS.md injections
                        firstUserText = String(t.prefix(80))
                        break
                    }
                }
                if firstUserText != nil { break }
            }
        }

        return (firstUserText, cwd)
    }

    /// Parse a Codex JSONL transcript into messages.
    private func parseCodexTranscript(at path: String) -> [CLIConversationMessage] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var messages: [CLIConversationMessage] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "response_item",
                  let payload = json["payload"] as? [String: Any] else { continue }

            let role = payload["role"] as? String ?? ""
            guard role == "user" || role == "assistant" else { continue }

            // Extract text content
            var text = ""
            if let content = payload["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    if blockType == "input_text" || blockType == "output_text" {
                        let t = block["text"] as? String ?? ""
                        if !t.hasPrefix("<") && !t.hasPrefix("#") { // skip system prompts
                            text += t
                        }
                    }
                }
            } else if let content = payload["content"] as? String {
                text = content
            }

            guard !text.isEmpty else { continue }

            messages.append(CLIConversationMessage(
                id: UUID().uuidString,
                role: role == "assistant" ? .assistant : .user,
                content: String(text.prefix(5000)),
                thinking: nil, toolName: nil, timestamp: nil
            ))
        }
        return messages
    }

    // MARK: - Gemini: ~/.gemini/tmp/<hash>/chats/session-*.json

    func readGeminiSessions(limit: Int = 100) -> [CLIHistoryEntry] {
        let tmpDir = home.appendingPathComponent(".gemini/tmp")
        guard fm.fileExists(atPath: tmpDir.path) else { return [] }

        var sessions: [CLIHistoryEntry] = []

        guard let hashDirs = try? fm.contentsOfDirectory(atPath: tmpDir.path) else { return [] }

        for hashDir in hashDirs {
            let chatsDir = tmpDir.appendingPathComponent(hashDir).appendingPathComponent("chats")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir.path) else { continue }

            for file in files {
                guard file.hasPrefix("session-"), file.hasSuffix(".json") else { continue }

                let filePath = chatsDir.appendingPathComponent(file)

                guard let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                let sessionId = String(file.dropFirst(8).dropLast(5)) // remove "session-" and ".json"

                // Read first user message from Gemini session
                let displayText = readFirstGeminiUserMessage(from: filePath.path)

                sessions.append(CLIHistoryEntry(
                    id: sessionId, cliType: .gemini,
                    displayText: displayText ?? sessionId,
                    timestamp: modDate,
                    project: filePath.path
                ))
            }
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { $0 }
    }

    private func readFirstGeminiUserMessage(from path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Try common Gemini session structures
        if let messages = json["messages"] as? [[String: Any]] {
            for msg in messages where msg["role"] as? String == "user" {
                if let parts = msg["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            return String(text.prefix(80))
                        }
                    }
                }
                if let content = msg["content"] as? String, !content.isEmpty {
                    return String(content.prefix(80))
                }
            }
        }

        // Alternative: history array
        if let history = json["history"] as? [[String: Any]] {
            for item in history where item["role"] as? String == "user" {
                if let parts = item["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            return String(text.prefix(80))
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Parse a Gemini session JSON into messages.
    private func parseGeminiSession(at path: String) -> [CLIConversationMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var messages: [CLIConversationMessage] = []

        let items = (json["messages"] as? [[String: Any]])
            ?? (json["history"] as? [[String: Any]])
            ?? []

        for item in items {
            let role = item["role"] as? String ?? "user"
            var text = ""

            if let parts = item["parts"] as? [[String: Any]] {
                text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else if let content = item["content"] as? String {
                text = content
            }

            guard !text.isEmpty else { continue }

            messages.append(CLIConversationMessage(
                id: UUID().uuidString,
                role: role == "model" || role == "assistant" ? .assistant : role == "tool" ? .tool : .user,
                content: String(text.prefix(5000)),
                thinking: nil, toolName: nil, timestamp: nil
            ))
        }

        return messages
    }

    // MARK: - Qwen: ~/.qwen/projects/<path>/chats/<session>.jsonl

    func readQwenSessions(limit: Int = 100) -> [CLIHistoryEntry] {
        let projectsDir = home.appendingPathComponent(".qwen/projects")
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: projectsDir.path) else { return [] }

        var sessions: [CLIHistoryEntry] = []

        for projDir in projectDirs {
            let projPath = projectsDir.appendingPathComponent(projDir)
            let chatsDir = projPath.appendingPathComponent("chats")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: chatsDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir.path) else { continue }

            for file in files {
                guard file.hasSuffix(".jsonl") else { continue }
                let filePath = chatsDir.appendingPathComponent(file)
                let sessionId = String(file.dropLast(6)) // remove .jsonl

                guard let attrs = try? fm.attributesOfItem(atPath: filePath.path),
                      let modDate = attrs[.modificationDate] as? Date else { continue }

                // 跳过空文件
                if let size = attrs[.size] as? Int, size == 0 { continue }

                let displayText = readFirstQwenUserMessage(from: filePath.path) ?? sessionId

                sessions.append(CLIHistoryEntry(
                    id: sessionId, cliType: .qwen,
                    displayText: displayText, timestamp: modDate,
                    project: filePath.path
                ))
            }
        }

        return sessions.sorted { $0.timestamp > $1.timestamp }.prefix(limit).map { $0 }
    }

    private func readFirstQwenUserMessage(from path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 8192)
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["type"] as? String == "user",
                  let message = json["message"] as? [String: Any],
                  let parts = message["parts"] as? [[String: Any]] else { continue }

            // Qwen: message.parts[].text
            for part in parts {
                if part["thought"] as? Bool == true { continue }
                if let t = part["text"] as? String, !t.isEmpty {
                    return String(t.prefix(80))
                }
            }
        }
        return nil
    }

    private func parseQwenTranscript(at path: String) -> [CLIConversationMessage] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var messages: [CLIConversationMessage] = []

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            let uuid = json["uuid"] as? String ?? UUID().uuidString

            // 跳过 system/ui_telemetry 等非对话记录
            if json["subtype"] != nil { continue }

            switch type {
            case "user":
                guard let message = json["message"] as? [String: Any],
                      let parts = message["parts"] as? [[String: Any]] else { continue }

                var userText = ""
                for part in parts {
                    if part["thought"] as? Bool == true { continue }
                    if let t = part["text"] as? String {
                        userText += t
                    }
                }
                if !userText.isEmpty {
                    messages.append(CLIConversationMessage(
                        id: uuid, role: .user, content: userText,
                        thinking: nil, toolName: nil, timestamp: nil
                    ))
                }

            case "assistant":
                guard let message = json["message"] as? [String: Any],
                      let parts = message["parts"] as? [[String: Any]] else { continue }

                var text = ""
                var thinking: String?

                for part in parts {
                    if part["thought"] as? Bool == true {
                        thinking = part["text"] as? String
                    } else if let t = part["text"] as? String {
                        text += t
                    }
                }

                if !text.isEmpty {
                    messages.append(CLIConversationMessage(
                        id: uuid, role: .assistant, content: text,
                        thinking: thinking, toolName: nil, timestamp: nil
                    ))
                }

            default: break
            }
        }
        return messages
    }
}
