// BattleLM/Services/DependencyChecker.swift
import Foundation

/// CLI 可用性状态
enum CLIStatus: Equatable {
    case notInstalled       // 命令不存在
    case broken             // 已安装但不可执行/损坏
    case installed          // 已安装（可执行）
    case ready              // 完全可用（已认证）
    
    var displayText: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .broken: return "Installed but not runnable"
        case .installed: return "Installed (needs login)"
        case .ready: return "Ready to use"
        }
    }
    
    var iconName: String {
        switch self {
        case .notInstalled: return "xmark.circle.fill"
        case .broken: return "exclamationmark.triangle.fill"
        case .installed: return "exclamationmark.circle.fill"
        case .ready: return "checkmark.circle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .notInstalled: return "red"
        case .broken: return "red"
        case .installed: return "orange"
        case .ready: return "green"
        }
    }
}

/// 依赖检查器 - 检查运行所需的依赖项
struct DependencyChecker {
    
    // MARK: - Dependency Definitions
    
    struct Dependency: Hashable {
        let name: String
        let command: String
        let installHint: String
        let installURL: String?
    }
    
    /// 必需的依赖
    static let required: [Dependency] = [
        Dependency(
            name: "tmux",
            command: "tmux",
            installHint: "brew install tmux",
            installURL: nil
        )
    ]
    
    /// AI CLI 依赖 - 小白友好安装指令 (2025)
    static let aiCLIs: [AIType: Dependency] = [
        .claude: Dependency(
            name: "Claude CLI",
            command: "claude",
            installHint: """
                ✨ 推荐（一键安装，复制粘贴到终端）:
                curl -fsSL https://claude.ai/install.sh | bash
                
                📦 备选（需要 Homebrew）:
                brew install --cask claude-code
                
                💡 没有 Homebrew? 先安装它:
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                """,
            installURL: "https://docs.anthropic.com/en/docs/claude-code/overview"
        ),
        .gemini: Dependency(
            name: "Gemini CLI",
            command: "gemini",
            installHint: """
                ✨ 推荐（需要 Node.js）:
                npm install -g @google/gemini-cli
                
                📦 备选（需要 Homebrew）:
                brew install gemini-cli
                
                💡 没有 Node.js? 先安装它:
                brew install node
                
                💡 没有 Homebrew? 先安装它:
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                """,
            installURL: "https://github.com/google-gemini/gemini-cli"
        ),
        .codex: Dependency(
            name: "Codex CLI",
            command: "codex",
            installHint: """
                ✨ 推荐（需要 Node.js 18+）:
                npm install -g @openai/codex
                
                📦 备选（需要 Homebrew）:
                brew install --cask codex
                
                💡 没有 Node.js? 先安装它:
                brew install node
                
                💡 没有 Homebrew? 先安装它:
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                """,
            installURL: "https://github.com/openai/codex"
        ),
        .qwen: Dependency(
            name: "Qwen CLI",
            command: "qwen",
            installHint: """
                ✨ 推荐（需要 Node.js 20+）:
                npm install -g @qwen-code/qwen-code@latest
                
                📦 备选（需要 Homebrew）:
                brew install qwen-code
                
                💡 没有 Node.js? 先安装它:
                brew install node
                
                💡 没有 Homebrew? 先安装它:
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                """,
            installURL: "https://github.com/QwenLM/qwen-code"
        ),
        .kimi: Dependency(
            name: "Kimi CLI",
            command: "kimi",
            installHint: """
                ✨ 安装步骤（需要 Python 3.13+）:
                
                1️⃣ 先安装 uv 包管理器:
                curl -LsSf https://astral.sh/uv/install.sh | sh
                
                2️⃣ 然后安装 Kimi CLI:
                uv tool install --python 3.13 kimi-cli
                
                💡 没有 Python? 用 Homebrew 安装:
                brew install python@3.13
                
                💡 没有 Homebrew? 先安装它:
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                """,
            installURL: "https://github.com/MoonshotAI/kimi-cli"
        )
    ]
    
    // MARK: - Check Methods
    
    /// 检查所有必需依赖
    static func checkRequired() async -> [Dependency: Bool] {
        var results: [Dependency: Bool] = [:]
        
        for dep in required {
            results[dep] = await commandExists(dep.command)
        }
        
        return results
    }
    
    /// 检查特定 AI 的 CLI 状态（使用登录 shell）
    static func checkAI(_ type: AIType) async -> CLIStatus {
        guard let dep = aiCLIs[type] else { return .notInstalled }
        
        // 1. 检查命令是否存在（使用登录 shell）
        let exists = await commandExists(dep.command)
        guard exists else { return .notInstalled }
        
        // 2. 检查版本（确保可执行）
        let versionOK = await checkVersion(dep.command)
        guard versionOK else { return .broken }
        
        // 3. 检查认证状态
        let hasAuth = checkAuthConfig(for: type)
        return hasAuth ? .ready : .installed
    }
    
    /// 简单检查（兼容旧代码）
    static func checkAIAvailable(_ type: AIType) async -> Bool {
        let status = await checkAI(type)
        return status != .notInstalled && status != .broken
    }
    
    /// 获取缺失的依赖
    static func getMissingDependencies() async -> [Dependency] {
        var missing: [Dependency] = []
        
        let results = await checkRequired()
        for (dep, available) in results {
            if !available {
                missing.append(dep)
            }
        }
        
        return missing
    }
    
    /// 获取可用的 AI 类型
    static func getAvailableAITypes() async -> [AIType] {
        var available: [AIType] = []
        
        for type in AIType.allCases {
            let status = await checkAI(type)
            if status != .notInstalled && status != .broken {
                available.append(type)
            }
        }
        
        return available
    }
    
    // MARK: - Private Helpers
    
    /// 使用登录 shell 检查命令是否存在
    private static func commandExists(_ command: String) async -> Bool {
        let cmd = "command -v \(command)"
        if let result = try? await runZsh(cmd, interactive: false, timeoutSeconds: 2.0) {
            if result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        // 兜底：部分用户把 PATH 配在 ~/.zshrc（interactive 才加载），这里用 login+interactive 再试一次
        if let result = try? await runZsh(cmd, interactive: true, timeoutSeconds: 2.0) {
            return result.exitCode == 0 && !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }
    
    /// 检查版本（确保命令可执行）
    private static func checkVersion(_ command: String) async -> Bool {
        let cmd = "\(command) --version 2>/dev/null || \(command) -v 2>/dev/null || \(command) --help 2>/dev/null"
        if let result = try? await runZsh(cmd, interactive: false, timeoutSeconds: 6.0) {
            if result.exitCode == 0 { return true }
        }
        // 兜底：interactive 环境下再试（避免 PATH 仅在 ~/.zshrc）
        if let result = try? await runZsh(cmd, interactive: true, timeoutSeconds: 6.0) {
            return result.exitCode == 0
        }
        return false
    }
    
    /// 检查认证配置文件
    private static func checkAuthConfig(for type: AIType) -> Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        
        let configPaths: [String]
        switch type {
        case .claude:
            configPaths = ["\(homeDir)/.claude", "\(homeDir)/.config/claude"]
        case .gemini:
            configPaths = ["\(homeDir)/.gemini", "\(homeDir)/.config/gemini"]
        case .codex:
            configPaths = ["\(homeDir)/.codex", "\(homeDir)/.config/codex"]
        case .qwen:
            configPaths = ["\(homeDir)/.qwen", "\(homeDir)/.config/qwen"]
        case .kimi:
            configPaths = ["\(homeDir)/.kimi", "\(homeDir)/.config/kimi"]
        }
        
        return configPaths.contains { path in
            FileManager.default.fileExists(atPath: path)
        }
    }
    
    /// 使用 zsh 执行命令：
    /// - `-l` 读取登录 shell 环境（更接近用户在 Terminal.app 的 PATH）
    /// - 可选 `-i` 读取 interactive 配置（兼容用户把 PATH 写在 ~/.zshrc 的情况）
    private static func runZsh(_ command: String, interactive: Bool, timeoutSeconds: TimeInterval) async throws -> CommandResult {
        return try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let guardQueue = DispatchQueue(label: "battlelm.dependencychecker.runZsh.resumeOnce")
            var didResume = false
            
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = [interactive ? "-lic" : "-lc", command]
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            @Sendable func resumeOnce(_ result: Result<CommandResult, Error>) {
                let shouldResume: Bool = guardQueue.sync {
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
            
            do {
                try task.run()

                task.terminationHandler = { _ in
                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = CommandResult(
                        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8) ?? "",
                        exitCode: task.terminationStatus
                    )
                    resumeOnce(.success(result))
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds) {
                    let shouldTerminate = guardQueue.sync { !didResume }
                    guard shouldTerminate else { return }

                    if task.isRunning {
                        task.terminate()
                    }
                }
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }
}

// MARK: - Dependency Check Result

struct DependencyCheckResult {
    let requiredMissing: [DependencyChecker.Dependency]
    let availableAIs: [AIType]
    
    var isReady: Bool {
        requiredMissing.isEmpty && !availableAIs.isEmpty
    }
}
