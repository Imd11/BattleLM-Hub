// BattleLM/Services/TokenUsageMonitor.swift
// Token 用量监控服务 — 扫描并监听 Claude Code 和 Codex 的本地 JSONL 日志文件。
//
// 数据来源：
//   Claude: ~/.claude/projects/<encoded-path>/<session-uuid>.jsonl
//   Codex:  ~/.codex/sessions/*.jsonl
//
// 工作流程：
//   1. 启动时扫描所有今天修改的 JSONL 文件，解析 token 用量
//   2. 用 DispatchSource 监听目录变化，增量解析新数据
//   3. 聚合到 TokenUsageSummary 并通过 @Observable 通知 UI

import Foundation
import Observation

@Observable
final class TokenUsageMonitor {
    
    // MARK: - Published State
    
    /// 当前时间范围的 token 用量汇总
    var summary = TokenUsageSummary()
    
    /// 当前选择的时间范围
    var selectedTimeRange: UsageTimeRange = .day24h {
        didSet { if oldValue != selectedTimeRange { refresh() } }
    }
    
    /// 是否正在扫描
    var isScanning = false
    
    /// 上次更新时间
    var lastUpdated: Date?
    
    // MARK: - Private
    
    private let queue = DispatchQueue(label: "com.battlelm.tokenMonitor", qos: .utility)
    private var directorySources: [DispatchSourceFileSystemObject] = []
    private var fileWatchers: [String: FileWatcher] = [:]   // path → watcher
    private var refreshTimer: DispatchSourceTimer?           // 定时刷新
    
    /// 根据当前时间范围计算的起始日期
    private var rangeStartDate: Date? { selectedTimeRange.startDate }
    
    /// 单个文件的监听状态
    private struct FileWatcher {
        let source: DispatchSourceFileSystemObject
        var offset: UInt64
    }

    /// Codex token_count 事件去重签名
    private struct CodexUsageSignature: Equatable {
        let model: String
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
    }

    /// Codex 累计用量快照（用于识别重复上报的 token_count 事件）
    private struct CodexCumulativeUsageSignature: Equatable {
        let input: Int
        let output: Int
        let cacheRead: Int
        let reasoning: Int
        let total: Int
    }
    
    // MARK: - Public API
    
    /// 开始监控。扫描历史数据 + 监听实时更新。
    func startMonitoring() {
        queue.async { [weak self] in
            guard let self else { return }
            
            DispatchQueue.main.async { self.isScanning = true }
            
            // 1. 初始扫描数据
            self.scanData()
            
            // 2. 开始监听目录变化
            self.watchDirectories()
            
            // 3. 启动定时刷新（30 秒一次）
            self.startPeriodicRefresh()
            
            DispatchQueue.main.async {
                self.isScanning = false
                self.lastUpdated = Date()
            }
        }
    }
    
    /// 停止监控
    func stopMonitoring() {
        refreshTimer?.cancel()
        refreshTimer = nil
        
        for source in directorySources {
            source.cancel()
        }
        directorySources.removeAll()
        
        for (_, watcher) in fileWatchers {
            watcher.source.cancel()
        }
        fileWatchers.removeAll()
    }
    
    /// 手动刷新（重新扫描今日数据）
    func refresh() {
        queue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.isScanning = true }
            
            self.scanData()
            
            DispatchQueue.main.async {
                self.isScanning = false
                self.lastUpdated = Date()
            }
        }
    }
    
    /// 定时刷新（补充 DispatchSource 无法检测深层子目录变化的问题）
    private func startPeriodicRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.scanData()
        }
        timer.resume()
        refreshTimer = timer
    }
    
    deinit { stopMonitoring() }
    
    // MARK: - Scanning
    
    /// 扫描指定时间范围内的数据
    private func scanData() {
        var newSummary = TokenUsageSummary()
        
        for source in TokenSource.allCases {
            let records = scanSource(source)
            for record in records {
                // 按时间范围过滤
                if let start = rangeStartDate, record.timestamp < start { continue }
                newSummary.addRecord(record)
            }
        }
        
        DispatchQueue.main.async { [newSummary] in
            self.summary = newSummary
        }
    }
    
    /// 扫描某个来源的所有今日日志
    private func scanSource(_ source: TokenSource) -> [TokenRecord] {
        let baseDir = source.logDirectory
        var records: [TokenRecord] = []
        
        switch source {
        case .claude:
            // Claude: ~/.claude/projects/ 下有多个项目目录，每个里面有 session JSONL
            records = scanClaudeDirectory(baseDir)
        case .codex:
            // Codex: ~/.codex/sessions/年/月/日/ 下有 JSONL（嵌套目录结构）
            records = scanDirectoryRecursively(baseDir, source: .codex)
        case .qwen:
            // Qwen: ~/.qwen/projects/<encoded-path>/chats/ 下有 JSONL（类似 Claude）
            records = scanDirectoryRecursively(baseDir, source: .qwen)
        case .gemini:
            // Gemini: ~/.gemini/tmp/<hash>/chats/session-*.json（单独的 JSON 文件，非 JSONL）
            records = scanGeminiDirectory(baseDir)
        }
        
        return records
    }
    
    /// 扫描 Claude 项目目录（需要递归一层子目录）
    private func scanClaudeDirectory(_ baseDir: String) -> [TokenRecord] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }
        
        var records: [TokenRecord] = []
        for dir in projectDirs {
            let projectPath = (baseDir as NSString).appendingPathComponent(dir)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: projectPath, isDirectory: &isDir), isDir.boolValue else { continue }
            
            records += scanJSONLDirectory(projectPath, source: .claude)
        }
        return records
    }
    
    /// 扫描一个目录下指定时间范围内修改过的 JSONL 文件
    private func scanJSONLDirectory(_ dir: String, source: TokenSource) -> [TokenRecord] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        
        var records: [TokenRecord] = []
        
        for file in files where file.hasSuffix(".jsonl") {
            let fullPath = (dir as NSString).appendingPathComponent(file)
            
            guard isFileInRange(fullPath) else { continue }
            
            let fileRecords = parseJSONLFile(fullPath, source: source)
            records += fileRecords
        }
        
        return records
    }
    
    /// 递归扫描目录树中所有今天修改的 JSONL 文件（适用于 Codex 的 年/月/日 嵌套结构）
    private func scanDirectoryRecursively(_ baseDir: String, source: TokenSource) -> [TokenRecord] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
        
        var records: [TokenRecord] = []
        
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            let fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
            
            guard isFileInRange(fullPath) else { continue }
            
            let fileRecords = parseJSONLFile(fullPath, source: source)
            records += fileRecords
        }
        
        return records
    }
    
    /// 扫描 Gemini 的 session JSON 文件（~/.gemini/tmp/<hash>/chats/session-*.json）
    private func scanGeminiDirectory(_ baseDir: String) -> [TokenRecord] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseDir) else { return [] }
        
        var records: [TokenRecord] = []
        
        while let relativePath = enumerator.nextObject() as? String {
            guard relativePath.hasSuffix(".json"),
                  relativePath.contains("/chats/session-") else { continue }
            let fullPath = (baseDir as NSString).appendingPathComponent(relativePath)
            
            guard isFileInRange(fullPath) else { continue }
            
            records += parseGeminiSessionFile(fullPath)
        }
        
        return records
    }
    
    /// 解析单个 Gemini session JSON 文件
    private func parseGeminiSessionFile(_ path: String) -> [TokenRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else { return [] }
        
        var records: [TokenRecord] = []
        
        for msg in messages {
            guard msg["type"] as? String == "gemini",
                  let tokens = msg["tokens"] as? [String: Any],
                  let tsStr = msg["timestamp"] as? String,
                  let timestamp = parseTimestamp(tsStr) else { continue }
            
            // 按时间范围过滤
            guard isTimestampInRange(timestamp) else { continue }
            
            let model = msg["model"] as? String ?? "unknown"
            let inputTokens = tokens["input"] as? Int ?? 0
            let outputTokens = tokens["output"] as? Int ?? 0
            let cacheRead = tokens["cached"] as? Int ?? 0
            
            guard inputTokens > 0 || outputTokens > 0 else { continue }
            
            records.append(TokenRecord(
                timestamp: timestamp, model: model, source: .gemini,
                inputTokens: inputTokens, outputTokens: outputTokens,
                cacheReadTokens: cacheRead, cacheWriteTokens: 0
            ))
        }
        
        return records
    }
    
    // MARK: - Time Range Helpers
    
    /// 检查文件修改日期是否在时间范围内
    private func isFileInRange(_ path: String) -> Bool {
        guard let start = rangeStartDate else { return true }  // nil = 无限制
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return modDate >= start
    }
    
    /// 检查时间戳是否在时间范围内
    private func isTimestampInRange(_ date: Date) -> Bool {
        guard let start = rangeStartDate else { return true }  // nil = 无限制
        return date >= start
    }
    
    // MARK: - JSONL Parsing
    
    /// 解析单个 JSONL 文件中的 token 用量
    private func parseJSONLFile(_ path: String, source: TokenSource) -> [TokenRecord] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        
        var records: [TokenRecord] = []
        var claudeRecordsByRequest: [String: TokenRecord] = [:]
        var codexCurrentModel: String? = nil
        var codexLastUsageSignature: CodexUsageSignature? = nil
        var codexLastCumulativeUsage: CodexCumulativeUsageSignature? = nil
        let lines = text.components(separatedBy: "\n")
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if source == .codex,
               json["type"] as? String == "turn_context",
               let payload = json["payload"] as? [String: Any],
               let model = nonEmptyString(payload["model"]) {
                codexCurrentModel = model
            }
            
            if let record = extractTokenRecord(from: json, source: source, fallbackModel: codexCurrentModel) {
                if source == .codex {
                    if let cumulative = codexCumulativeUsageSignature(from: json) {
                        // 更可靠：同一个累计快照被重复上报时直接跳过
                        if codexLastCumulativeUsage == cumulative {
                            continue
                        }
                        codexLastCumulativeUsage = cumulative
                    } else {
                        // 兜底：当日志缺少 total_token_usage 时，回退到本轮签名相邻去重
                        let signature = CodexUsageSignature(
                            model: record.model,
                            input: record.inputTokens,
                            output: record.outputTokens,
                            cacheRead: record.cacheReadTokens,
                            cacheWrite: record.cacheWriteTokens
                        )
                        if codexLastUsageSignature == signature {
                            continue
                        }
                        codexLastUsageSignature = signature
                    }

                }

                // 按时间范围过滤
                if isTimestampInRange(record.timestamp) {
                    if source == .claude, let requestID = claudeRequestID(from: json) {
                        if let existing = claudeRecordsByRequest[requestID] {
                            claudeRecordsByRequest[requestID] = preferredClaudeRecord(existing, record)
                        } else {
                            claudeRecordsByRequest[requestID] = record
                        }
                    } else {
                        records.append(record)
                    }
                }
            }
        }
        
        if source == .claude {
            records.append(contentsOf: claudeRecordsByRequest.values)
        }
        
        return records
    }
    
    /// Claude 会把同一次请求（同一个 message.id）写成多条 assistant 事件，需按请求去重。
    private func claudeRequestID(from json: [String: Any]) -> String? {
        guard json["type"] as? String == "assistant",
              let message = json["message"] as? [String: Any],
              let requestID = message["id"] as? String,
              !requestID.isEmpty else { return nil }
        return requestID
    }
    
    /// 同一 Claude 请求的多条 usage 中，保留“最完整”的一条（通常 output 更大，代表最终事件）。
    private func preferredClaudeRecord(_ existing: TokenRecord, _ candidate: TokenRecord) -> TokenRecord {
        if candidate.outputTokens != existing.outputTokens {
            return candidate.outputTokens > existing.outputTokens ? candidate : existing
        }
        if candidate.totalTokens != existing.totalTokens {
            return candidate.totalTokens > existing.totalTokens ? candidate : existing
        }
        return candidate.timestamp >= existing.timestamp ? candidate : existing
    }
    
    /// 从单行 JSON 中提取 token 用量记录
    private func extractTokenRecord(from json: [String: Any], source: TokenSource, fallbackModel: String? = nil) -> TokenRecord? {
        // 获取时间戳
        let timestamp: Date
        if let ts = json["timestamp"] as? String {
            timestamp = parseTimestamp(ts) ?? Date()
        } else if let ts = json["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: ts)
        } else {
            return nil
        }
        
        // 提取 usage 数据 — 不同来源的字段位置不同
        switch source {
        case .claude:
            // Claude: type=assistant 的行里 message.usage 包含 token 数据
            guard json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return nil }
            let model = message["model"] as? String ?? "unknown"
            
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int
                ?? usage["cached_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            
            guard inputTokens > 0 || outputTokens > 0 else { return nil }
            
            return TokenRecord(
                timestamp: timestamp, model: model, source: source,
                inputTokens: inputTokens, outputTokens: outputTokens,
                cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite
            )
            
        case .codex:
            // Codex: type="event_msg" 且 payload.type="token_count" 的行里
            // payload.info.last_token_usage 包含单次请求的 token 数据
            guard json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any] else { return nil }
            
            // model 字段可能在 info 里，也可能需要从 usage 中提取
            let model = nonEmptyString(info["model"])
                ?? nonEmptyString(usage["model"])
                ?? nonEmptyString(payload["model"])
                ?? fallbackModel
                ?? "unknown"
            
            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0
            let cacheRead = usage["cached_input_tokens"] as? Int
                ?? usage["cache_read_input_tokens"] as? Int
                ?? usage["cached_tokens"] as? Int ?? 0
            let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
            
            guard inputTokens > 0 || outputTokens > 0 else { return nil }
            
            return TokenRecord(
                timestamp: timestamp, model: model, source: source,
                inputTokens: inputTokens, outputTokens: outputTokens,
                cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite
            )
            
        case .qwen:
            // Qwen: type=system + subtype=ui_telemetry 行里 systemPayload.uiEvent 包含 token 数据
            guard json["type"] as? String == "system",
                  json["subtype"] as? String == "ui_telemetry",
                  let payload = json["systemPayload"] as? [String: Any],
                  let uiEvent = payload["uiEvent"] as? [String: Any] else { return nil }
            
            let model = uiEvent["model"] as? String ?? "unknown"
            let inputTokens = uiEvent["input_token_count"] as? Int ?? 0
            let outputTokens = uiEvent["output_token_count"] as? Int ?? 0
            let cacheRead = uiEvent["cached_content_token_count"] as? Int ?? 0
            
            guard inputTokens > 0 || outputTokens > 0 else { return nil }
            
            return TokenRecord(
                timestamp: timestamp, model: model, source: source,
                inputTokens: inputTokens, outputTokens: outputTokens,
                cacheReadTokens: cacheRead, cacheWriteTokens: 0
            )
            
        case .gemini:
            // Gemini 使用独立的 parseGeminiSessionFile，不走 JSONL 解析
            return nil
        }
    }

    /// 统一处理可能为空字符串的 JSON 字段
    private func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 提取 Codex 累计 token 用量快照（payload.info.total_token_usage）
    private func codexCumulativeUsageSignature(from json: [String: Any]) -> CodexCumulativeUsageSignature? {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let totalUsage = info["total_token_usage"] as? [String: Any] else { return nil }

        let input = totalUsage["input_tokens"] as? Int ?? 0
        let output = totalUsage["output_tokens"] as? Int ?? 0
        let cacheRead = totalUsage["cached_input_tokens"] as? Int
            ?? totalUsage["cache_read_input_tokens"] as? Int
            ?? totalUsage["cached_tokens"] as? Int ?? 0
        let reasoning = totalUsage["reasoning_output_tokens"] as? Int ?? 0
        let total = totalUsage["total_tokens"] as? Int ?? (input + output)

        return CodexCumulativeUsageSignature(
            input: input,
            output: output,
            cacheRead: cacheRead,
            reasoning: reasoning,
            total: total
        )
    }
    
    // MARK: - Directory Watching
    
    /// 监听日志目录变化
    private func watchDirectories() {
        for source in TokenSource.allCases {
            let dir = source.logDirectory
            
            switch source {
            case .claude:
                // Claude 需要监听 projects 目录下的所有子目录
                watchDirectory(dir, source: source, recursive: true)
            case .codex:
                watchDirectory(dir, source: source, recursive: false)
            case .qwen:
                // Qwen 类似 Claude，需要递归监听
                watchDirectory(dir, source: source, recursive: true)
            case .gemini:
                // Gemini 需要递归监听 tmp 下的所有子目录
                watchDirectory(dir, source: source, recursive: true)
            }
        }
    }
    
    /// 监听单个目录
    private func watchDirectory(_ dir: String, source: TokenSource, recursive: Bool) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir) else {
            print("⚠️ TokenMonitor: directory not found: \(dir)")
            return
        }
        
        // 如果是递归模式（Claude），监听每个子目录
        if recursive {
            guard let subdirs = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for subdir in subdirs {
                let fullPath = (dir as NSString).appendingPathComponent(subdir)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }
                watchSingleDirectory(fullPath, source: source)
            }
        } else {
            watchSingleDirectory(dir, source: source)
        }
    }
    
    /// 创建目录级 DispatchSource
    private func watchSingleDirectory(_ dir: String, source: TokenSource) {
        guard let fd = open(dir, O_EVTONLY) as Int32?,
              fd >= 0 else { return }
        
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )
        
        src.setEventHandler { [weak self] in
            self?.onDirectoryChanged(dir, source: source)
        }
        
        src.setCancelHandler {
            close(fd)
        }
        
        src.resume()
        directorySources.append(src)
    }
    
    /// 目录发生变化时，重新扫描数据
    private func onDirectoryChanged(_ dir: String, source: TokenSource) {
        // 全量重扫，保证所有来源（包括 Gemini 的 .json 文件）都被覆盖
        scanData()
    }
    
    // MARK: - Timestamp Parsing
    
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    
    private static let isoFormatterNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    
    private func parseTimestamp(_ str: String) -> Date? {
        Self.isoFormatter.date(from: str) ?? Self.isoFormatterNoFrac.date(from: str)
    }
}
