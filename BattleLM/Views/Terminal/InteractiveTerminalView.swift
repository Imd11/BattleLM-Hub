// BattleLM/Views/Terminal/InteractiveTerminalView.swift
import SwiftUI
import SwiftTerm
import AppKit

/// 交互式终端视图 - 使用 SwiftTerm 提供真实终端体验
struct InteractiveTerminalView: NSViewRepresentable {
    let ai: AIInstance
    @Binding var isConnected: Bool
    var onConnectionFailed: (() -> Void)?
    
    // 固定终端尺寸防止 reflow 影响 capture-pane
    private let fixedCols: Int = 120
    private let fixedRows: Int = 30
    
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        // 注意：SwiftTerm 的滚动缓冲区默认 500 行，暂无公开 API 修改
        // 用户需使用 Snapshot 模式查看完整历史
        let terminal = LocalProcessTerminalView(frame: .zero)
        context.coordinator.terminal = terminal
        context.coordinator.ai = ai
        context.coordinator.onConnectionFailed = onConnectionFailed
        
        // 配置终端外观 - 使用支持中文的等宽字体
        // Menlo 支持基本字符，系统会自动 fallback 到中文字体
        if let menloFont = NSFont(name: "Menlo", size: 11) {
            terminal.font = menloFont
        } else {
            terminal.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        }
        
        // 设置代理
        terminal.processDelegate = context.coordinator
        
        // 启动 tmux attach
        context.coordinator.startTmuxAttach(for: ai)
        
        return terminal
    }
    
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // 更新时不需要做额外操作
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(isConnected: $isConnected)
    }
    
    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminal: LocalProcessTerminalView?
        var ai: AIInstance?
        @Binding var isConnected: Bool
        var onConnectionFailed: (() -> Void)?
        private var reconnectAttempts = 0
        private let maxReconnectAttempts = 3
        
        init(isConnected: Binding<Bool>) {
            _isConnected = isConnected
        }
        
        func startTmuxAttach(for ai: AIInstance) {
            guard let terminal = terminal else { return }
            
            let sessionName = ai.tmuxSession
            let tmuxPath = "/opt/homebrew/bin/tmux"
            
            // 检查会话是否存在
            Task {
                let exists = try? await SessionManager.shared.sessionExists(sessionName)
                
                await MainActor.run {
                    if exists == true {
                        // 使用独立 socket (-L battlelm) attach 到会话
                        terminal.startProcess(
                            executable: tmuxPath,
                            args: ["-L", "battlelm", "attach", "-t", sessionName],
                            environment: nil,
                            execName: nil
                        )
                        self.isConnected = true
                        self.reconnectAttempts = 0
                    } else {
                        print("⚠️ Session \(sessionName) not found")
                        self.isConnected = false
                        self.onConnectionFailed?()
                    }
                }
            }
        }
        
        private func attemptReconnect() {
            guard reconnectAttempts < maxReconnectAttempts,
                  let ai = ai else {
                onConnectionFailed?()
                return
            }
            
            reconnectAttempts += 1
            print("🔄 Reconnecting... attempt \(reconnectAttempts)/\(maxReconnectAttempts)")
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startTmuxAttach(for: ai)
            }
        }
        
        // MARK: - LocalProcessTerminalViewDelegate
        
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // 终端大小变化时自动处理
        }
        
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // 可以用来更新窗口标题
        }
        
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // 目录变化通知
        }
        
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                self.isConnected = false
                
                // 尝试重连（非正常退出时）
                if let code = exitCode, code != 0 {
                    self.attemptReconnect()
                }
            }
        }
    }
}

#Preview {
    InteractiveTerminalView(
        ai: AIInstance(
            type: .claude,
            name: "Claude",
            workingDirectory: "~/Desktop"
        ),
        isConnected: .constant(true)
    )
    .frame(width: 400, height: 300)
}
