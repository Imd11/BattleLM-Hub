import Foundation
import Combine

/// 管理 cloudflared Quick Tunnel（免费临时隧道）
/// 每个用户运行时会获得自己独立的 trycloudflare.com 临时地址
@MainActor
class CloudflaredManager: ObservableObject {
    static let shared = CloudflaredManager()
    
    @Published var tunnelURL: String?
    @Published var isRunning = false
    @Published var error: String?
    
    private var process: Process?
    private var outputPipe: Pipe?
    
    private init() {}
    
    /// 检查是否已安装
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cloudflared") ||
        FileManager.default.fileExists(atPath: "/usr/local/bin/cloudflared")
    }
    
    private var cloudflaredPath: String? {
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/cloudflared") {
            return "/opt/homebrew/bin/cloudflared"
        }
        if FileManager.default.fileExists(atPath: "/usr/local/bin/cloudflared") {
            return "/usr/local/bin/cloudflared"
        }
        return nil
    }
    
    /// Start Quick Tunnel (每个用户获得独立的临时地址)
    func startTunnel(localPort: Int) async throws -> String {
        guard let path = cloudflaredPath else {
            throw CloudflaredError.notInstalled
        }
        
        // Stop existing process
        stop()
        
        isRunning = false
        tunnelURL = nil
        error = nil
        
        process = Process()
        process?.executableURL = URL(fileURLWithPath: path)
        process?.arguments = ["tunnel", "--url", "http://127.0.0.1:\(localPort)"]
        
        outputPipe = Pipe()
        process?.standardError = outputPipe  // cloudflared outputs to stderr
        
        try process?.run()
        
        // Stream read and parse output
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                guard let pipe = outputPipe else {
                    continuation.resume(throwing: CloudflaredError.noOutput)
                    return
                }
                
                let handle = pipe.fileHandleForReading
                var buffer = ""
                let timeout: TimeInterval = 30
                
                // Stream reading
                handle.readabilityHandler = { [weak self] fileHandle in
                    let data = fileHandle.availableData
                    guard !data.isEmpty else { return }
                    
                    buffer += String(data: data, encoding: .utf8) ?? ""
                    
                    // Find URL
                    if let range = buffer.range(of: "https://[a-z0-9-]+\\.trycloudflare\\.com",
                                                 options: .regularExpression) {
                        let httpsURL = String(buffer[range])
                        let wssURL = httpsURL.replacingOccurrences(of: "https://", with: "wss://")
                        
                        handle.readabilityHandler = nil
                        
                        Task { @MainActor in
                            self?.tunnelURL = wssURL
                            self?.isRunning = true
                        }
                        
                        continuation.resume(returning: wssURL)
                    }
                }
                
                // Timeout check
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                
                if tunnelURL == nil {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: CloudflaredError.timeout)
                }
            }
        }
    }
    
    func stop() {
        process?.terminate()
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        tunnelURL = nil
        isRunning = false
    }
    
    enum CloudflaredError: Error, LocalizedError {
        case notInstalled
        case noOutput
        case timeout
        case tunnelFailed
        
        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Please install cloudflared first: brew install cloudflared"
            case .noOutput:
                return "Unable to get cloudflared output"
            case .timeout:
                return "Tunnel startup timed out (30s)"
            case .tunnelFailed:
                return "Tunnel startup failed"
            }
        }
    }
}
