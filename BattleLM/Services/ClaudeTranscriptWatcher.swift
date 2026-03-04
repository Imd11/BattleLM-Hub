// BattleLM/Services/ClaudeTranscriptWatcher.swift
// JSONL Transcript Watcher — 监听 Claude Code 的实时对话日志。
//
// Claude Code 运行时把每次对话追加写入 JSONL 文件：
//   ~/.claude/projects/<encoded-path>/<session-uuid>.jsonl
//
// 用 DispatchSource 监听文件写入事件，增量读取新行，解析 JSON 后回调。

import Foundation

// MARK: - Transcript Event

/// 从 JSONL 解析出的结构化事件。
enum TranscriptEvent {
    /// Claude 的文本回复
    case text(String)
    /// Claude 的内部思考（extended thinking）
    case thinking(String)
    /// 工具调用（function call）
    case toolUse(id: String, name: String, input: String)
    /// 工具执行结果
    case toolResult(toolUseId: String, output: String)
    /// 回复结束（stop_reason）
    case turnComplete
}

// MARK: - Transcript Watcher

/// 监听 Claude Code 写入的 JSONL transcript 文件，实时推送解析后的事件。
final class ClaudeTranscriptWatcher {

    /// 事件回调
    var onEvent: ((TranscriptEvent) -> Void)?

    /// 当前监听的文件路径
    private(set) var watchedFile: String?

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var fileOffset: UInt64 = 0
    private var partialLine: String = "" // 处理跨 read 的不完整行
    private let queue = DispatchQueue(label: "com.battlelm.transcript", qos: .userInitiated)

    // MARK: - Public API

    /// 开始监听指定项目路径下最新的 JSONL 文件。
    /// - Parameters:
    ///   - projectPath: 项目工作目录（如 `/Users/yang/Desktop/GitHub`）
    ///   - fromTail: 是否只读新增内容（true = 跳到文件末尾，false = 从头读）
    func watchLatest(projectPath: String, fromTail: Bool = true) {
        // Claude Code 编码路径规则：/ → -
        let encodedPath = projectPath
            .replacingOccurrences(of: "/", with: "-")
        // 去掉开头多余的 -（如果原路径以 / 开头）
        let cleanEncoded = encodedPath.hasPrefix("-") ? encodedPath : "-\(encodedPath)"

        let claudeProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(cleanEncoded)")

        // 找到最新的 session JSONL（排除 agent- 开头的子 agent 文件）
        guard let latestFile = findLatestJSONL(in: claudeProjectDir.path) else {
            print("⚠️ TranscriptWatcher: no JSONL found in \(claudeProjectDir.path)")
            return
        }

        watch(file: latestFile, fromTail: fromTail)
    }

    /// 开始监听指定的 JSONL 文件。
    func watch(file path: String, fromTail: Bool = true) {
        stop() // 停止之前的监听

        guard let fh = FileHandle(forReadingAtPath: path) else {
            print("⚠️ TranscriptWatcher: cannot open \(path)")
            return
        }

        self.fileHandle = fh
        self.watchedFile = path

        if fromTail {
            // 从文件末尾开始（只读新增内容）
            fh.seekToEndOfFile()
            fileOffset = fh.offsetInFile
        } else {
            fileOffset = 0
        }

        // 创建 DispatchSource 监听文件写入事件
        let fd = fh.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.readNewContent()
        }

        src.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }

        src.resume()
        self.source = src

        print("👁️ TranscriptWatcher: monitoring \(path) (fromTail: \(fromTail))")
    }

    /// 重新扫描项目目录，切换到最新的 JSONL 文件。
    /// 用于 Claude 创建新 session 后更新监听目标。
    func refreshLatest(projectPath: String) {
        let encodedPath = projectPath.replacingOccurrences(of: "/", with: "-")
        let cleanEncoded = encodedPath.hasPrefix("-") ? encodedPath : "-\(encodedPath)"
        let claudeProjectDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(cleanEncoded)")

        guard let latestFile = findLatestJSONL(in: claudeProjectDir.path) else { return }

        // 如果最新文件变了，切换监听
        if latestFile != watchedFile {
            print("🔄 TranscriptWatcher: session changed → \(latestFile)")
            watch(file: latestFile, fromTail: true)
        }
    }

    /// 停止监听。
    func stop() {
        source?.cancel()
        source = nil
        watchedFile = nil
        fileOffset = 0
        partialLine = ""
    }

    deinit { stop() }

    // MARK: - Private

    /// 读取文件新增内容，按行解析 JSON。
    private func readNewContent() {
        guard let fh = fileHandle else { return }

        fh.seek(toFileOffset: fileOffset)
        let data = fh.readDataToEndOfFile()
        guard !data.isEmpty else { return }

        fileOffset = fh.offsetInFile

        guard let text = String(data: data, encoding: .utf8) else { return }

        // 拼接上次的不完整行
        let fullText = partialLine + text
        let lines = fullText.components(separatedBy: "\n")

        // 最后一个元素可能是不完整的行（如果 text 不以 \n 结尾）
        if fullText.hasSuffix("\n") {
            partialLine = ""
        } else {
            partialLine = lines.last ?? ""
        }

        // 处理完整的行
        let completeLines = fullText.hasSuffix("\n") ? lines : Array(lines.dropLast())

        for line in completeLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let events = parseTranscriptLine(json)
            for event in events {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(event)
                }
            }
        }
    }

    /// 解析一行 JSONL → TranscriptEvent 数组。
    private func parseTranscriptLine(_ json: [String: Any]) -> [TranscriptEvent] {
        guard let type = json["type"] as? String else { return [] }
        var events: [TranscriptEvent] = []

        switch type {
        case "assistant":
            // 助手回复：可能包含 thinking / text / tool_use
            guard let message = json["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return [] }

            for block in content {
                guard let blockType = block["type"] as? String else { continue }
                switch blockType {
                case "thinking":
                    if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                        events.append(.thinking(thinking))
                    }
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty {
                        events.append(.text(text))
                    }
                case "tool_use":
                    let id = block["id"] as? String ?? ""
                    let name = block["name"] as? String ?? ""
                    let input: String
                    if let inputObj = block["input"] {
                        if let inputData = try? JSONSerialization.data(withJSONObject: inputObj),
                           let inputStr = String(data: inputData, encoding: .utf8) {
                            input = inputStr
                        } else {
                            input = String(describing: inputObj)
                        }
                    } else {
                        input = ""
                    }
                    events.append(.toolUse(id: id, name: name, input: input))
                default:
                    break
                }
            }

            // 检查 stop_reason 判断是否回复结束
            if let stopReason = (json["message"] as? [String: Any])?["stop_reason"] as? String,
               stopReason == "end_turn" || stopReason == "stop_sequence" {
                events.append(.turnComplete)
            }

        case "tool":
            // 工具执行结果
            if let message = json["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "tool_result" {
                    let toolUseId = block["tool_use_id"] as? String ?? ""
                    let output: String
                    if let resultContent = block["content"] as? [[String: Any]] {
                        output = resultContent
                            .compactMap { $0["text"] as? String }
                            .joined(separator: "\n")
                    } else if let text = block["content"] as? String {
                        output = text
                    } else {
                        output = ""
                    }
                    events.append(.toolResult(toolUseId: toolUseId, output: output))
                }
            }

        default:
            // queue-operation, system, user 等——暂不处理
            break
        }

        return events
    }

    /// 找到目录中最新修改的 session JSONL 文件（排除 agent- 子 agent 文件）。
    private func findLatestJSONL(in dir: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }

        var newest: String?
        var newestTime: Date = .distantPast

        for entry in entries {
            // 只看顶层 session 文件（UUID.jsonl），排除 agent-xxx.jsonl
            guard entry.hasSuffix(".jsonl"),
                  !entry.hasPrefix("agent-") else { continue }

            let fullPath = (dir as NSString).appendingPathComponent(entry)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath),
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            if modDate > newestTime {
                newestTime = modDate
                newest = fullPath
            }
        }

        return newest
    }
}
