// BattleLM/Services/ClaudePTYSession.swift
// PTY-based interactive Claude session — 用 pty 控制交互式 claude 进程。
//
// 牛马AI 方案：不用 `claude -p`，而是启动交互式 `claude`，
// 通过 pty stdin 发消息，通过 JSONL 文件监听读取结构化回复。
// 交互式模式自动处理认证，支持多轮对话。

import Foundation
import Darwin

/// 管理一个 pty-based 的交互式 Claude Code 进程。
/// 消息通过 pty master fd 写入，回复通过 `ClaudeTranscriptWatcher` 读取。
final class ClaudePTYSession {
    /// 活跃的 pty sessions [AI ID: Session]
    static var activeSessions: [UUID: ClaudePTYSession] = [:]
    private static let sessionsLock = NSLock()

    let aiId: UUID
    private var masterFd: Int32 = -1
    private var process: Process?
    private let queue = DispatchQueue(label: "com.battlelm.pty", qos: .userInitiated)

    /// Claude Code session ID（从 JSONL 文件名推断）
    private(set) var sessionId: String?

    /// 进程是否仍在运行
    var isRunning: Bool { process?.isRunning ?? false }

    init(aiId: UUID) {
        self.aiId = aiId
    }

    // MARK: - Lifecycle

    /// 启动交互式 claude 进程，通过 pty 连接。
    /// - Parameter cwd: 工作目录
    func start(cwd: String) throws {
        guard !isRunning else { return }

        var slaveFd: Int32 = 0
        var slaveName = [CChar](repeating: 0, count: 1024)

        // 创建 pty pair
        guard openpty(&masterFd, &slaveFd, &slaveName, nil, nil) == 0 else {
            throw SessionError.commandFailed("Failed to open pty")
        }

        // 设置 pty 大小（120x40，匹配 tmux 设置）
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        ioctl(masterFd, TIOCSWINSZ, &winSize)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 交互式 claude：自动处理认证、多轮对话、工具调用
        // unset ANTHROPIC_API_KEY 防止 settings.json 里过期的 key 干扰
        proc.arguments = ["-lc", "unset ANTHROPIC_API_KEY; claude"]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        // 把 slave fd 连接到子进程的 stdin/stdout/stderr
        let slaveFileHandle = FileHandle(fileDescriptor: slaveFd, closeOnDealloc: false)
        proc.standardInput = slaveFileHandle
        proc.standardOutput = slaveFileHandle
        proc.standardError = slaveFileHandle

        // 进程退出时清理
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            print("🔴 Claude pty process exited for AI \(self.aiId)")
            self.cleanup()
        }

        try proc.run()
        close(slaveFd) // parent 只用 master fd

        self.process = proc
        Self.sessionsLock.withLock { Self.activeSessions[aiId] = self }

        print("✅ ClaudePTYSession started (pid: \(proc.processIdentifier), cwd: \(cwd))")

        // 启动一个 reader 从 master 消费输出（防止 pty buffer 满导致阻塞）
        startDrainReader()
    }

    /// 通过 pty 发送消息（模拟用户在终端输入）
    func send(_ message: String) {
        guard masterFd >= 0 else {
            print("⚠️ ClaudePTYSession: master fd invalid, cannot send")
            return
        }
        queue.async { [masterFd] in
            let data = (message + "\n").data(using: .utf8)!
            data.withUnsafeBytes { buf in
                if let base = buf.baseAddress {
                    _ = write(masterFd, base, data.count)
                }
            }
        }
    }

    /// 发送 Escape 中断当前操作
    func sendEscape() {
        guard masterFd >= 0 else { return }
        queue.async { [masterFd] in
            var esc: UInt8 = 0x1b // ESC
            _ = write(masterFd, &esc, 1)
        }
    }

    /// 停止 claude 进程
    func stop() {
        // 先尝试优雅退出
        send("/exit")

        // 给 claude 1 秒时间退出
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let proc = self.process, proc.isRunning else { return }
            print("⚠️ ClaudePTYSession: force terminating")
            proc.terminate()
        }
    }

    // MARK: - Private

    /// 从 master fd 持续读取输出，防止 pty buffer 满阻塞子进程。
    /// 输出内容不做解析（回复通过 JSONL 文件监听获取）。
    private func startDrainReader() {
        queue.async { [weak self] in
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }

            while let self, self.masterFd >= 0 {
                let n = read(self.masterFd, buf, 4096)
                if n <= 0 { break } // EOF or error
                // 可选：打印到 Xcode 控制台用于调试
                // let str = String(bytes: UnsafeBufferPointer(start: buf, count: n), encoding: .utf8) ?? ""
                // print("[pty] \(str)")
            }
        }
    }

    private func cleanup() {
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }
        process = nil
        Self.sessionsLock.withLock { Self.activeSessions.removeValue(forKey: aiId) }
    }

    deinit {
        cleanup()
    }
}
