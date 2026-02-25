// BattleLM/Views/Chat/MessageInputView.swift
import SwiftUI

/// 消息输入框视图
struct MessageInputView: View {
    @Binding var inputText: String
    @Binding var selectedMode: ChatMode
    @Binding var soloTargetAIId: UUID?
    var onSend: () -> Void
    
    @EnvironmentObject var appState: AppState
    @FocusState private var isFocused: Bool
    @ObservedObject private var discussionManager = DiscussionManager.shared
    @State private var isModeMenuOpen = false
    @State private var isModeHovered = false
    @State private var isSoloMenuOpen = false
    @State private var isSoloHovered = false
    
    private var isBattling: Bool {
        discussionManager.isProcessing
    }
    
    /// 群聊成员 AI 列表
    private var memberAIs: [AIInstance] {
        guard let chat = appState.selectedGroupChat else { return [] }
        return appState.aiInstances.filter { chat.memberIds.contains($0.id) }
    }
    
    /// Solo 模式下选中的 AI 名称
    private var soloTargetName: String? {
        guard let id = soloTargetAIId else { return nil }
        return appState.aiInstance(for: id)?.name
    }
    
    /// Solo 模式下是否可以发送
    private var isSoloReady: Bool {
        selectedMode == .solo ? soloTargetAIId != nil : true
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // 模式选择器（自定义弹出样式）
            Button {
                if !isBattling { isModeMenuOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedMode.iconName)
                        .font(.system(size: 13))
                    Text(selectedMode.displayName)
                        .font(.system(size: 13))
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isModeMenuOpen ? Color.accentColor.opacity(0.15) : (isModeHovered ? Color.primary.opacity(0.12) : Color.clear))
                )
                .foregroundColor(.primary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .frame(width: selectedMode == .discussion ? 110 : 90, alignment: .leading)
            .onHover { hovering in
                isModeHovered = hovering
            }
            .disabled(isBattling)
            .background(
                Group {
                    if isModeMenuOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .frame(width: 10000, height: 10000)
                            .fixedSize()
                            .onTapGesture { isModeMenuOpen = false }
                    }
                }
            )
            .overlay(alignment: .bottomLeading) {
                if isModeMenuOpen {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(ChatMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            ModeMenuRow(mode: mode, isSelected: mode == selectedMode) {
                                selectedMode = mode
                                isModeMenuOpen = false
                            }
                            
                            if index < ChatMode.allCases.count - 1 {
                                Divider()
                                    .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(width: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.windowBackgroundColor))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: -2)
                    )
                    .offset(y: -36)
                }
            }
            
            // Solo 模式：AI 选择器
            if selectedMode == .solo {
                Button {
                    if !isBattling { isSoloMenuOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        if let targetId = soloTargetAIId,
                           let targetAI = appState.aiInstance(for: targetId) {
                            AILogoView(aiType: targetAI.type, size: 16)
                            Text(targetAI.name)
                                .font(.system(size: 13))
                                .fontWeight(.medium)
                        } else {
                            Text("Select AI")
                                .font(.system(size: 13))
                                .fontWeight(.medium)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSoloMenuOpen ? Color.primary.opacity(0.15) : (isSoloHovered ? Color.primary.opacity(0.12) : Color.clear))
                    )
                    .foregroundColor(.primary)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isSoloHovered = hovering
                }
                .disabled(isBattling)
                .background(
                    Group {
                        if isSoloMenuOpen {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: 10000, height: 10000)
                                .fixedSize()
                                .onTapGesture { isSoloMenuOpen = false }
                        }
                    }
                )
                .overlay(alignment: .bottomLeading) {
                    if isSoloMenuOpen {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(memberAIs.enumerated()), id: \.element.id) { index, ai in
                                SoloAIRow(ai: ai, isSelected: soloTargetAIId == ai.id) {
                                    soloTargetAIId = ai.id
                                    isSoloMenuOpen = false
                                }
                                
                                if index < memberAIs.count - 1 {
                                    Divider()
                                        .padding(.horizontal, 8)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(width: 180)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.windowBackgroundColor))
                                .shadow(color: .black.opacity(0.25), radius: 8, y: -2)
                        )
                        .offset(y: -36)
                    }
                }
            }
            
            // 输入框
            TextField(isBattling ? "AIs are battling..." : modePlaceholder, text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isFocused)
                .disabled(isBattling)
                .onSubmit {
                    if !inputText.isEmpty && isSoloReady {
                        onSend()
                    }
                }
            
            // 发送按钮
            Button {
                onSend()
            } label: {
                Text(sendButtonTitle)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(sendButtonBackground)
                    .foregroundColor(sendButtonForeground)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(isBattling || !isSoloReady || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }
    
    // MARK: - Computed Properties
    
    private var sendButtonTitle: String {
        if isBattling { return "⚔️ Battling..." }
        switch selectedMode {
        case .solo: return "Send"
        default: return "Let's Battle"
        }
    }
    
    private var sendButtonBackground: Color {
        if isBattling { return Color.orange.opacity(0.3) }
        let isEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selectedMode == .solo && !isSoloReady { return Color.gray.opacity(0.3) }
        return isEmpty ? Color.gray.opacity(0.3) : Color(hex: "#A3390E")
    }
    
    private var sendButtonForeground: Color {
        if isBattling { return .orange }
        let isEmpty = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if selectedMode == .solo && !isSoloReady { return .gray }
        return isEmpty ? .gray : .white
    }
    
    private var modeColor: Color {
        switch selectedMode {
        case .discussion: return .blue
        case .qna: return .green
        case .solo: return .purple
        }
    }
    
    private var modePlaceholder: String {
        switch selectedMode {
        case .discussion:
            return "Describe the problem for AI discussion..."
        case .qna:
            return "Ask all AIs a question..."
        case .solo:
            if soloTargetAIId == nil {
                return "Select an AI first..."
            }
            return "Send a message to \(soloTargetName ?? "AI")..."
        }
    }
}

#Preview {
    MessageInputView(
         inputText: .constant(""),
        selectedMode: .constant(.discussion),
        soloTargetAIId: .constant(nil)
    ) {
        print("Send")
    }
    .environmentObject(AppState())
    .frame(width: 500)
}

/// 模式菜单行 - 带 hover 效果
private struct ModeMenuRow: View {
    let mode: ChatMode
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(mode.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Solo 模式 AI 选择行
private struct SoloAIRow: View {
    let ai: AIInstance
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AILogoView(aiType: ai.type, size: 18)
                
                Text(ai.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
