// BattleLM/Services/QwenTranscriptExtractor.swift
import Foundation

/// Qwen transcript 提取器
/// 从 ~/.qwen/projects/<encoded_path>/chats/*.jsonl 读取结构化数据
/// 格式与 Claude 极其相似，字段名略有不同（parts vs content, role:"model" vs "assistant"）
class QwenTranscriptExtractor {
    
    /// 错误类型
    enum ExtractionError: Error, LocalizedError {
        case transcriptNotFound(String)
        case noUserMessage
        case noAssistantResponse
        case parseError(String)
        
        var errorDescription: String? {
            switch self {
            case .transcriptNotFound(let path):
                return "Qwen transcript not found at: \(path)"
            case .noUserMessage:
                return "No user message found in Qwen transcript"
            case .noAssistantResponse:
                return "No assistant response found after last user message"
            case .parseError(let detail):
                return "Qwen JSONL parse error: \(detail)"
            }
        }
    }
    
    // MARK: - JSONL Entry Models
    
    /// Qwen JSONL 行的顶层结构
    /// 示例:
    /// {"uuid":"...","type":"user","message":{"role":"user","parts":[{"text":"say hi"}]}}
    /// {"uuid":"...","type":"assistant","message":{"role":"model","parts":[{"text":"思考","thought":true},{"text":"Hi! 👋"}]}}
    private struct TranscriptEntry: Decodable {
        let type: String                // "user" | "assistant" | "system"
        let message: Message?
        let uuid: String?
        let parentUuid: String?
        let timestamp: String?
        let sessionId: String?
        let subtype: String?            // system entries have subtype like "ui_telemetry"
        
        struct Message: Decodable {
            let role: String?           // "user" | "model"
            let parts: [Part]?
        }
        
        struct Part: Decodable {
            let text: String?
            let thought: Bool?          // true = thinking content
        }
    }
    
    // MARK: - Public API
    
    /// 从 Qwen transcript 提取最后一条 assistant 响应
    static func extractLatestResponse(workingDirectory: String) throws -> String {
        guard let transcriptPath = transcriptURL(for: workingDirectory) else {
            throw ExtractionError.transcriptNotFound(workingDirectory)
        }
        return try parseTranscript(at: transcriptPath, afterUserUuid: nil)
    }
    
    /// 异步版本：轮询 transcript 直到内容稳定
    static func streamLatestResponse(transcriptURL: URL,
                                      afterUserUuid: String?,
                                      expectedUserText: String?,
                                      minTimestamp: Date?,
                                      onUpdate: @escaping (String, Bool) -> Void,
                                      stableSeconds: Double = 3.0,
                                      maxWait: Double = 120.0) async throws -> String {
        let startTime = Date()
        var lastContent = ""
        var lastChangeTime = Date()
        var lastModTime: Date? = nil
        var target: (uuid: String, index: Int)? = nil
        
        while Date().timeIntervalSince(startTime) < maxWait {
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)
            let modTime = attrs?[.modificationDate] as? Date
            
            if modTime != lastModTime {
                do {
                    let entries = try parseEntries(at: transcriptURL)
                    
                    if target == nil {
                        if let found = findTargetUser(
                            in: entries,
                            afterUserUuid: afterUserUuid,
                            expectedUserText: expectedUserText,
                            minTimestamp: minTimestamp
                        ) {
                            target = found
                        } else {
                            lastModTime = modTime
                            continue
                        }
                    }
                    
                    let content = try extractAssistantText(
                        from: entries,
                        userIndex: target!.index,
                        userUuid: target!.uuid
                    )
                    
                    if content != lastContent && !content.isEmpty {
                        lastContent = content
                        lastChangeTime = Date()
                        
                        await MainActor.run {
                            onUpdate(content, false)
                        }
                    }
                    
                    lastModTime = modTime
                } catch {
                    print("⚠️ Qwen transcript parse error (will retry): \(error)")
                }
            }
            
            if !lastContent.isEmpty && Date().timeIntervalSince(lastChangeTime) >= stableSeconds {
                await MainActor.run {
                    onUpdate(lastContent, true)
                }
                return lastContent
            }
            
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
        
        if !lastContent.isEmpty {
            await MainActor.run {
                onUpdate(lastContent, true)
            }
            return lastContent
        }
        
        throw ExtractionError.noAssistantResponse
    }
    
    /// 获取 transcript 中最后一条 user 的 uuid
    static func latestUserUuid(workingDirectory: String) throws -> String {
        guard let transcriptPath = transcriptURL(for: workingDirectory) else {
            throw ExtractionError.transcriptNotFound(workingDirectory)
        }
        return try latestUserUuid(in: transcriptPath)
    }
    
    /// 获取 Qwen transcript 文件 URL
    static func transcriptURL(for workingDirectory: String) -> URL? {
        findTranscriptFile(for: workingDirectory)
    }
    
    /// 检查 transcript 是否可用
    static func isTranscriptAvailable(for workingDirectory: String) -> Bool {
        return findTranscriptFile(for: workingDirectory) != nil
    }
    
    // MARK: - Private Helpers
    
    /// 查找 Qwen transcript 文件
    /// Qwen 路径编码: / → -（和 Claude 一致）
    /// 结构: ~/.qwen/projects/<encoded_path>/chats/<session_id>.jsonl
    private static func findTranscriptFile(for workingDirectory: String) -> URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let qwenProjectsDir = homeDir.appendingPathComponent(".qwen/projects")
        
        let expandedPath: String
        if workingDirectory.hasPrefix("~") {
            expandedPath = homeDir.path + workingDirectory.dropFirst()
        } else if workingDirectory.isEmpty {
            expandedPath = homeDir.path
        } else {
            expandedPath = workingDirectory
        }
        
        // 编码规则：/ 替换为 -
        let encoded = expandedPath.replacingOccurrences(of: "/", with: "-")
        
        let withoutLeadingDash: String
        if encoded.hasPrefix("-") {
            withoutLeadingDash = String(encoded.dropFirst())
        } else {
            withoutLeadingDash = encoded
        }
        
        let prefixesToTry = [
            encoded,             // -Users-yang-Desktop-GitHub-xxx
            withoutLeadingDash   // Users-yang-Desktop-GitHub-xxx
        ]
        
        for prefix in prefixesToTry {
            let projectDir = qwenProjectsDir.appendingPathComponent(prefix)
            // Qwen 把聊天文件放在 chats/ 子目录
            let chatsDir = projectDir.appendingPathComponent("chats")
            
            guard FileManager.default.fileExists(atPath: chatsDir.path) else {
                continue
            }
            
            if let latestJsonl = findLatestJsonl(in: chatsDir) {
                print("✅ Found Qwen transcript: \(latestJsonl.path)")
                return latestJsonl
            }
        }
        
        print("⚠️ Qwen transcript not found for: \(workingDirectory)")
        return nil
    }
    
    /// 查找最新的 .jsonl 文件
    private static func findLatestJsonl(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }
        
        let jsonlFiles = contents.filter { url in
            guard url.pathExtension == "jsonl" else { return false }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == 0 {
                return false
            }
            return fileContainsConversationMarkers(url)
        }
        
        let sorted = jsonlFiles.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate > bDate
        }
        
        return sorted.first
    }
    
    /// 解析 transcript，提取指定 user 消息后的 assistant 响应
    private static func parseTranscript(at url: URL, afterUserUuid: String?) throws -> String {
        let entries = try parseEntries(at: url)
        
        let userIdx: Int
        if let afterUserUuid {
            guard let idx = entries.lastIndex(where: { $0.type == "user" && $0.uuid == afterUserUuid }) else {
                throw ExtractionError.noUserMessage
            }
            userIdx = idx
        } else {
            guard let idx = entries.lastIndex(where: { $0.type == "user" }) else {
                throw ExtractionError.noUserMessage
            }
            userIdx = idx
        }
        return try extractAssistantText(from: entries, userIndex: userIdx, userUuid: entries[userIdx].uuid)
    }
    
    private static func latestUserUuid(in url: URL) throws -> String {
        let entries = try parseEntries(at: url)
        var lastUserUuid: String? = nil
        for entry in entries {
            if entry.type == "user", let uuid = entry.uuid {
                lastUserUuid = uuid
            }
        }
        guard let result = lastUserUuid else { throw ExtractionError.noUserMessage }
        return result
    }
    
    private static func parseEntries(at url: URL) throws -> [TranscriptEntry] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw ExtractionError.noUserMessage }
        
        var entries: [TranscriptEntry] = []
        let decoder = JSONDecoder()
        for line in lines {
            guard let data = line.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(TranscriptEntry.self, from: data) {
                entries.append(entry)
            }
        }
        
        guard !entries.isEmpty else { throw ExtractionError.noUserMessage }
        return entries
    }
    
    private static func findTargetUser(
        in entries: [TranscriptEntry],
        afterUserUuid: String?,
        expectedUserText: String?,
        minTimestamp: Date?
    ) -> (uuid: String, index: Int)? {
        var baselineSeen = afterUserUuid == nil
        var found: (uuid: String, index: Int)? = nil
        
        for (index, entry) in entries.enumerated() {
            guard entry.type == "user" else { continue }
            guard let uuid = entry.uuid else { continue }
            // Qwen 的 system/ui_telemetry 记录跳过
            if entry.subtype != nil { continue }
            
            if let afterUserUuid, uuid == afterUserUuid {
                baselineSeen = true
                continue
            }
            guard baselineSeen else { continue }
            
            if let expectedUserText {
                let expected = normalizeUserText(expectedUserText)
                let actual = normalizeUserText(userText(from: entry))
                if expected != actual {
                    continue
                }
            }
            if let minTimestamp, let entryDate = parseTimestamp(entry.timestamp), entryDate < minTimestamp {
                continue
            }
            
            found = (uuid: uuid, index: index)
        }
        
        return found
    }
    
    /// 提取 user 之后的 assistant 文本（跳过 thinking 部分）
    private static func extractAssistantText(from entries: [TranscriptEntry], userIndex: Int, userUuid: String?) throws -> String {
        guard userIndex < entries.count else { throw ExtractionError.noUserMessage }
        guard let userUuid else { throw ExtractionError.noUserMessage }
        
        var textParts: [String] = []
        var chain: Set<String> = [userUuid]
        
        for i in (userIndex + 1)..<entries.count {
            let entry = entries[i]
            // 遇到下一个 user 消息就停止
            if entry.type == "user" {
                break
            }
            
            guard entry.type == "assistant" else { continue }
            guard let parentUuid = entry.parentUuid, chain.contains(parentUuid) else { continue }
            
            if let uuid = entry.uuid {
                chain.insert(uuid)
            }
            
            guard let msg = entry.message, let parts = msg.parts else { continue }
            for part in parts {
                // 跳过 thinking 内容，只提取正式回复
                if part.thought == true { continue }
                if let text = part.text, !text.isEmpty {
                    textParts.append(text)
                }
            }
        }
        
        guard !textParts.isEmpty else {
            throw ExtractionError.noAssistantResponse
        }
        
        return textParts.joined(separator: "\n\n")
    }
    
    /// 从 user entry 提取用户消息文本
    private static func userText(from entry: TranscriptEntry) -> String? {
        guard entry.type == "user", let msg = entry.message, let parts = msg.parts else { return nil }
        return parts.compactMap { $0.text }.joined()
    }
    
    private static func normalizeUserText(_ text: String?) -> String? {
        guard let text else { return nil }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func parseTimestamp(_ timestamp: String?) -> Date? {
        guard let timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
    }
    
    private static func fileContainsConversationMarkers(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"type\":\"user\"")
    }
}
