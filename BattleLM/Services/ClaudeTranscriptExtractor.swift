// BattleLM/Services/ClaudeTranscriptExtractor.swift
import Foundation

/// Claude transcript 提取器
/// 从 ~/.claude/projects/<encoded_path>/*.jsonl 读取结构化数据，避免解析 PTY 输出
class ClaudeTranscriptExtractor {
    
    /// 错误类型
    enum ExtractionError: Error, LocalizedError {
        case transcriptNotFound(String)
        case noUserMessage
        case noAssistantResponse
        case parseError(String)
        
        var errorDescription: String? {
            switch self {
            case .transcriptNotFound(let path):
                return "Transcript not found at: \(path)"
            case .noUserMessage:
                return "No user message found in transcript"
            case .noAssistantResponse:
                return "No assistant response found after last user message"
            case .parseError(let detail):
                return "JSONL parse error: \(detail)"
            }
        }
    }
    
    // MARK: - JSONL Entry Models
    
    /// JSONL 行的顶层结构
    private struct TranscriptEntry: Decodable {
        let type: String
        let message: Message?
        let uuid: String?
        let parentUuid: String?
        let timestamp: String?
        let userType: String?
        let isSidechain: Bool?
        
        struct Message: Decodable {
            let role: String?
            let content: ContentValue?
        }
        
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
            let thinking: String?
        }

        enum ContentValue: Decodable {
            case string(String)
            case blocks([ContentBlock])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let stringValue = try? container.decode(String.self) {
                    self = .string(stringValue)
                    return
                }
                self = .blocks(try container.decode([ContentBlock].self))
            }
        }
    }
    
    // MARK: - Public API
    
    /// 从 Claude transcript 提取最后一条 assistant 响应
    /// - Parameters:
    ///   - workingDirectory: AI 实例的工作目录（用于定位 Claude project）
    ///   - waitForStable: 是否等待内容稳定
    ///   - stableSeconds: 稳定判定时间
    /// - Returns: 完整的 assistant 响应文本
    static func extractLatestResponse(workingDirectory: String,
                                       waitForStable: Bool = false,
                                       stableSeconds: Double = 2.0) throws -> String {
        // 1. 查找 transcript 文件
        guard let transcriptPath = transcriptURL(for: workingDirectory) else {
            throw ExtractionError.transcriptNotFound(workingDirectory)
        }
        
        // 2. 读取并解析 JSONL
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
            // 检查文件修改时间
            let attrs = try? FileManager.default.attributesOfItem(atPath: transcriptURL.path)
            let modTime = attrs?[.modificationDate] as? Date
            
            // 文件有更新，重新解析
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
                            // 本轮 user 还没写入 transcript，继续等
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
                            onUpdate(content, false) // (内容, 是否完成)
                        }
                    }
                    
                    // 解析成功后再更新 modTime，避免写入中途解析失败导致“错过下一次重试”
                    lastModTime = modTime
                } catch {
                    // 解析失败时继续等待（可能文件正在写入）
                    print("⚠️ Transcript parse error (will retry): \(error)")
                }
            }
            
            // 检查是否稳定
            if !lastContent.isEmpty && Date().timeIntervalSince(lastChangeTime) >= stableSeconds {
                await MainActor.run {
                    onUpdate(lastContent, true) // 完成
                }
                return lastContent
            }
            
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
        
        // 超时但有内容
        if !lastContent.isEmpty {
            await MainActor.run {
                onUpdate(lastContent, true)
            }
            return lastContent
        }
        
        throw ExtractionError.noAssistantResponse
    }

    /// 获取 transcript 中最后一条 user 的 uuid（用于对齐本轮请求）
    static func latestUserUuid(workingDirectory: String) throws -> String {
        guard let transcriptPath = transcriptURL(for: workingDirectory) else {
            throw ExtractionError.transcriptNotFound(workingDirectory)
        }
        return try latestUserUuid(in: transcriptPath)
    }

    /// 获取 Claude transcript 文件 URL
    static func transcriptURL(for workingDirectory: String) -> URL? {
        findTranscriptFile(for: workingDirectory)
    }
    
    // MARK: - Private Helpers
    
    /// 查找 Claude transcript 文件
    /// 参考 claudecode-telegram/bridge.py 的编码规则
    private static func findTranscriptFile(for workingDirectory: String) -> URL? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let claudeProjectsDir = homeDir.appendingPathComponent(".claude/projects")
        
        // 规范化路径（展开 ~ 等）
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
        
        // 尝试两种前缀格式（有些 Claude 版本在开头加 -，有些不加）
        let prefixesToTry = [
            encoded,             // -Users-demo-Projects-xxx
            withoutLeadingDash   // Users-demo-Projects-xxx (去掉开头的 -)
        ]
        
        for prefix in prefixesToTry {
            let projectDir = claudeProjectsDir.appendingPathComponent(prefix)
            
            guard FileManager.default.fileExists(atPath: projectDir.path) else {
                continue
            }
            
            // 查找最新的 .jsonl 文件
            if let latestJsonl = findLatestJsonl(in: projectDir) {
                print("✅ Found Claude transcript: \(latestJsonl.path)")
                return latestJsonl
            }
        }
        
        print("⚠️ Claude transcript not found for: \(workingDirectory)")
        print("   Tried prefixes: \(prefixesToTry)")
        return nil
    }
    
    /// 在目录中查找最新的 .jsonl 文件
    private static func findLatestJsonl(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return nil
        }

        // Claude Code 会生成各种 jsonl（包含 agent-*.jsonl、空文件等），这里只选可能包含对话记录的文件
        let jsonlFiles = contents.filter { url in
            guard url.pathExtension == "jsonl" else { return false }
            let name = url.lastPathComponent
            if name.hasPrefix("agent-") { return false }
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size == 0 {
                return false
            }
            // 必须包含对话 user 记录，否则可能是 snapshot/summary 文件
            if !(fileContainsConversationMarkers(url)) {
                return false
            }
            return true
        }
        
        // 按修改时间排序，取最新
        let sorted = jsonlFiles.sorted { a, b in
            let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return aDate > bDate
        }
        
        return sorted.first
    }
    
    /// 解析 JSONL transcript，提取最后一个 user 消息后的 assistant 响应
    /// - Parameter afterUserUuid: 指定要绑定的 user uuid；为 nil 则自动使用最后一个 user
    private static func parseTranscript(at url: URL, afterUserUuid: String?) throws -> String {
        let entries = try parseEntries(at: url)
        
        // 从后往前找最后一个 user 消息
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
            guard entry.userType == nil || entry.userType == "external" else { continue }
            guard entry.isSidechain != true else { continue }
            guard let uuid = entry.uuid else { continue }
            
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
    
    private static func extractAssistantText(from entries: [TranscriptEntry], userIndex: Int, userUuid: String?) throws -> String {
        guard userIndex < entries.count else { throw ExtractionError.noUserMessage }
        guard let userUuid else { throw ExtractionError.noUserMessage }
        
        var textParts: [String] = []
        var chain: Set<String> = [userUuid]
        
        for i in (userIndex + 1)..<entries.count {
            let entry = entries[i]
            if entry.type == "user" {
                break
            }
            
            guard entry.type == "assistant" else { continue }
            guard let parentUuid = entry.parentUuid, chain.contains(parentUuid) else { continue }
            
            if let uuid = entry.uuid {
                chain.insert(uuid)
            }
            
            guard let msg = entry.message, let content = msg.content else { continue }
            switch content {
            case .blocks(let blocks):
                for block in blocks {
                    if block.type == "text", let text = block.text, !text.isEmpty {
                        textParts.append(text)
                    }
                }
            case .string:
                break
            }
        }
        
        guard !textParts.isEmpty else {
            throw ExtractionError.noAssistantResponse
        }
        
        return textParts.joined(separator: "\n\n")
    }

    private static func userText(from entry: TranscriptEntry) -> String? {
        guard entry.type == "user", let msg = entry.message, let content = msg.content else { return nil }
        switch content {
        case .string(let s):
            return s
        case .blocks:
            return nil
        }
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
        // quick scan for at least one user record; avoids snapshot-only files
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("\"type\":\"user\"")
    }
    
    /// 检查 transcript 是否可用于指定的工作目录
    static func isTranscriptAvailable(for workingDirectory: String) -> Bool {
        return findTranscriptFile(for: workingDirectory) != nil
    }
}
