// BattleLM/Views/Chat/ChatView.swift
import SwiftUI

/// 群聊视图
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @State private var inputText: String = ""
    @State private var selectedMode: ChatMode = .discussion
    @State private var soloTargetAIId: UUID? = nil
    
    var chat: GroupChat? {
        appState.selectedGroupChat
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            ChatHeaderView()
            
            Divider()
            
            // 消息列表
            MessageListView()
            
            Divider()
            
            // 输入框（带模式选择器）
            MessageInputView(
                inputText: $inputText,
                selectedMode: $selectedMode,
                soloTargetAIId: $soloTargetAIId
            ) {
                sendMessage()
            }
        }
        .background(Color(.textBackgroundColor).opacity(0.3))
        .onChange(of: selectedMode) { newMode in
            // 更新群聊模式
            updateChatMode(newMode)
        }
    }
    
    private func sendMessage() {
        guard let chat = chat, !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        appState.sendUserMessage(inputText, to: chat.id, soloTargetAIId: soloTargetAIId)
        inputText = ""
    }
    
    private func updateChatMode(_ mode: ChatMode) {
        guard let chatId = appState.selectedGroupChatId,
              let index = appState.groupChats.firstIndex(where: { $0.id == chatId }) else { return }
        
        appState.groupChats[index].mode = mode
    }
}

/// 聊天顶栏
struct ChatHeaderView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var discussionManager = DiscussionManager.shared
    
    var chat: GroupChat? {
        appState.selectedGroupChat
    }
    
    var memberCount: Int {
        chat?.memberIds.count ?? 0
    }
    
    var body: some View {
        HStack {
            // 群聊名称
            Text(chat?.name ?? "Chat")
                .font(.headline)
            
            // 成员头像
            HStack(spacing: -8) {
                ForEach(chat?.memberIds.prefix(4) ?? [], id: \.self) { memberId in
                    if let ai = appState.aiInstance(for: memberId) {
                        ZStack {
                            Circle()
                                .fill(Color(.windowBackgroundColor))
                                .frame(width: 24, height: 24)
                            AILogoView(aiType: ai.type, size: 18)
                        }
                        .overlay(
                            Circle()
                                .stroke(Color(.windowBackgroundColor), lineWidth: 2)
                        )
                    }
                }
                
                // 显示更多成员数量
                if memberCount > 4 {
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 24, height: 24)
                        .overlay(
                            Text("+\(memberCount - 4)")
                                .font(.caption2)
                                .foregroundColor(.white)
                        )
                        .overlay(
                            Circle()
                                .stroke(Color(.windowBackgroundColor), lineWidth: 2)
                        )
                }
            }
            
            // 成员数量
            Text("\(memberCount) AIs")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            // 当前回合/状态
            if let chat = chat {
                HStack(spacing: 8) {
                    Text("Round \(chat.currentRound)/\(chat.mode.maxRounds)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Stop 按钮（仅在讨论进行中显示）
                    if discussionManager.isProcessing {
                        Button {
                            discussionManager.cancelDiscussion()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9))
                                Text("Stop")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red.opacity(0.2))
                            .foregroundColor(.red)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    // 活跃 AI 数量
                    let activeCount = chat.memberIds.filter { id in
                        appState.aiInstance(for: id)?.isEliminated == false
                    }.count
                    
                    Text("\(activeCount) active")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(8)
                }
            }
            
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    ChatView()
        .environmentObject(AppState())
        .frame(width: 500, height: 600)
}

