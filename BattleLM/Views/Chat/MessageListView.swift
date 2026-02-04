// BattleLM/Views/Chat/MessageListView.swift
import SwiftUI

/// 消息列表视图
struct MessageListView: View {
    @EnvironmentObject var appState: AppState
    
    var messages: [Message] {
        appState.selectedGroupChat?.messages ?? []
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(messages) { message in
                            MessageBubbleView(message: message, containerWidth: geometry.size.width)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _ in
                    // 自动滚动到最新消息
                    if let lastMessage = messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}

/// 消息气泡视图
struct MessageBubbleView: View {
    let message: Message
    var containerWidth: CGFloat = 500  // 默认宽度
    @EnvironmentObject var appState: AppState
    
    var isUser: Bool {
        message.senderType == .user
    }
    
    var isSystem: Bool {
        message.senderType == .system
    }
    
    var aiInstance: AIInstance? {
        appState.aiInstance(for: message.senderId)
    }
    
    /// 消息气泡最大宽度（容器宽度的 70%）
    var maxBubbleWidth: CGFloat {
        max(containerWidth * 0.7, 200)  // 最小 200
    }
    
    var body: some View {
        if isSystem {
            // 系统消息
            systemMessageView
        } else {
            // 用户或 AI 消息
            regularMessageView
        }
    }
    
    // 系统消息样式
    private var systemMessageView: some View {
        HStack {
            Spacer()
            Text(message.content)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            Spacer()
        }
    }
    
    // 普通消息样式
    private var regularMessageView: some View {
        HStack(alignment: .top, spacing: 12) {
            // 左侧空白（10%）
            Spacer()
                .frame(width: containerWidth * 0.10)
            
            // 用户消息额外左边空白（推向右边）
            if isUser {
                Spacer()
            }
            
            // 左侧头像（AI 消息）
            if !isUser {
                avatarView
            }
            
            // 消息内容
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // 发送者名称和类型标签
                if !isUser {
                    HStack(spacing: 6) {
                        Text(message.senderName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(aiInstance?.color ?? .secondary)
                        
                        messageTypeTag
                    }
                }
                
                // 消息内容（带右键菜单）
                Text(message.content)
                    .padding(12)
                    .background(bubbleBackground)
                    .foregroundColor(bubbleTextColor)
                    .cornerRadius(16)
                    .frame(maxWidth: maxBubbleWidth, alignment: isUser ? .trailing : .leading)
                    .contextMenu {
                        // 仅 AI 消息显示反应菜单
                        if !isUser {
                            Button {
                                reactToMessage(.like)
                            } label: {
                                Label("👍 Like", systemImage: "hand.thumbsup.fill")
                            }
                            
                            Button {
                                reactToMessage(.dislike)
                            } label: {
                                Label("👎 Dislike", systemImage: "hand.thumbsdown.fill")
                            }
                            
                            Divider()
                            
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.content, forType: .string)
                            } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                        }
                    }
                
                // 用户反应显示
                if let reaction = message.userReaction {
                    Text(reaction.emoji)
                        .font(.system(size: 16))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15))
                        .cornerRadius(10)
                }
                
                // Solution 模式投票按钮已移除
                
                // 时间戳
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            // AI 消息额外右边空白
            if !isUser {
                Spacer()
            }
            
            // 右侧空白（10%）
            Spacer()
                .frame(width: containerWidth * 0.10)
        }
    }
    
    // Solution mode 已移除
    
    // voteButtonsView 和 eliminateAI 已删除
    
    // 用户反应处理
    private func reactToMessage(_ reaction: UserReaction) {
        guard let chatId = appState.selectedGroupChatId else { return }
        appState.setMessageReaction(reaction, for: message.id, in: chatId)
    }
    
    // 头像视图（带火焰效果）
    private var avatarView: some View {
        let flameIntensity = calculateFlameIntensity()
        
        return ZStack {
            // 火焰粒子层（在头像下方）
            if flameIntensity > 0 {
                FlameParticleView(intensity: flameIntensity, avatarSize: 28)
                    .offset(x: 0, y: 0)
            }
            
            // AI 头像
            if let ai = aiInstance {
                AILogoView(aiType: ai.type, size: 28)
                    .clipShape(Circle())
            }
        }
        .frame(width: 68, height: 68)  // 加大框架以容纳火焰
    }
    
    // 计算该 AI 的火焰强度
    private func calculateFlameIntensity() -> Int {
        guard let ai = aiInstance,
              let chat = appState.selectedGroupChat else { return 0 }
        return ai.calculateFlameIntensity(in: chat)
    }
    
    // 消息类型标签
    @ViewBuilder
    private var messageTypeTag: some View {
        if message.messageType != .question {
            Text(messageTypeText)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(messageTypeColor.opacity(0.2))
                .foregroundColor(messageTypeColor)
                .cornerRadius(4)
        }
    }
    
    private var messageTypeText: String {
        switch message.messageType {
        case .analysis: return "Analysis"
        case .evaluation: return "Evaluation"
        default: return ""
        }
    }
    
    private var messageTypeColor: Color {
        switch message.messageType {
        case .analysis: return .blue
        case .evaluation: return .orange
        default: return .gray
        }
    }
    
    private var bubbleBackground: Color {
        isUser ? Color.accentColor : Color(.controlBackgroundColor)
    }
    
    private var bubbleTextColor: Color {
        isUser ? .white : .primary
    }
}

#Preview {
    MessageListView()
        .environmentObject(AppState())
        .frame(width: 500, height: 400)
}
