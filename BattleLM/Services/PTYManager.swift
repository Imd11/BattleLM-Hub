// BattleLM/Services/PTYManager.swift
import Foundation

/// PTY 管理器 - 使用 Process + FileHandle 模拟真实终端
/// 注意：Swift 中 fork() 不可用，改用 Process 启动命令
class PTYManager {
    private var process: Process?
    private var masterHandle: FileHandle?
    private var slaveHandle: FileHandle?
    private var masterFd: Int32 = -1
    
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?
    
    var isConnected: Bool {
        return process?.isRunning ?? false
    }
    
    /// 启动进程并连接到 PTY
    /// - Parameters:
    ///   - cols: 初始列数
    ///   - rows: 初始行数
    func spawn(command: String, args: [String], cols: Int = 80, rows: Int = 24, environment: [String: String] = [:]) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var name = [CChar](repeating: 0, count: 128)
        
        // 设置初始窗口尺寸（在 openpty 时传入）
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        
        // 创建 PTY 并设置尺寸
        guard openpty(&master, &slave, &name, nil, &ws) == 0 else {
            throw PTYError.openptyFailed
        }
        
        masterFd = master
        masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        
        // 捕获回调，避免在多次 spawn/重连时串线
        let outputCallback = onOutput
        let exitCallback = onExit

        // 使用 Process 启动命令
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: command)
        proc.arguments = args
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        
        // 设置环境变量
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        for (key, value) in environment {
            env[key] = value
        }
        proc.environment = env
        
        // 连接到 PTY slave
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        
        // 退出回调
        proc.terminationHandler = { process in
            DispatchQueue.main.async {
                exitCallback?(process.terminationStatus)
            }
        }
        
        // 启动进程
        try proc.run()
        process = proc
        
        // 关闭 slave（子进程已经持有）
        Darwin.close(slave)
        
        // 设置读取监听
        setupReadHandler(outputCallback)
    }
    
    /// 写入数据到 PTY
    func write(_ data: Data) {
        guard let handle = masterHandle else { return }
        try? handle.write(contentsOf: data)
    }
    
    /// 写入字符串到 PTY
    func write(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
    
    /// 更新终端窗口大小
    func updateWindowSize(cols: Int, rows: Int) {
        guard masterFd >= 0 else { return }
        
        var ws = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
        
        // 发送 SIGWINCH 信号
        if let pid = process?.processIdentifier, pid > 0 {
            kill(pid, SIGWINCH)
        }
    }
    
    /// 关闭 PTY
    func closeConnection() {
        masterHandle?.readabilityHandler = nil
        masterHandle = nil
        slaveHandle = nil
        masterFd = -1
        
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
        process = nil
    }
    
    // MARK: - Private
    
    private func setupReadHandler(_ outputCallback: ((Data) -> Void)?) {
        guard let handle = masterHandle else { return }
        
        // 使用 readabilityHandler 监听输出
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty {
                DispatchQueue.main.async {
                    outputCallback?(data)
                }
            }
        }
    }
    
    deinit {
        closeConnection()
    }
}

// MARK: - Errors

enum PTYError: Error, LocalizedError {
    case openptyFailed
    case spawnFailed
    
    var errorDescription: String? {
        switch self {
        case .openptyFailed: return "Failed to create PTY"
        case .spawnFailed: return "Failed to spawn process"
        }
    }
}
