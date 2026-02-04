// BattleLM/Views/Chat/MessageInputView.swift
import SwiftUI

/// 消息输入框视图
struct MessageInputView: View {
    @Binding var inputText: String
    @Binding var selectedMode: ChatMode
    var onSend: () -> Void
    
    @FocusState private var isFocused: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            // 模式选择器
            Menu {
                ForEach(ChatMode.allCases) { mode in
                    Button {
                        selectedMode = mode
                    } label: {
                        Label(mode.displayName, systemImage: mode.iconName)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedMode.iconName)
                        .font(.caption)
                    Text(selectedMode.displayName)
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(modeColor.opacity(0.2))
                .foregroundColor(modeColor)
                .cornerRadius(8)
            }
            .menuStyle(.borderlessButton)
            
            // 输入框
            TextField(modePlaceholder, text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($isFocused)
                .onSubmit {
                    if !inputText.isEmpty {
                        onSend()
                    }
                }
            
            // 发送按钮 - Let's Battle!
            Button {
                onSend()
            } label: {
                Text("Let's Battle")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(inputText.isEmpty ? Color.gray.opacity(0.3) : Color.accentColor)
                    .foregroundColor(inputText.isEmpty ? .gray : .white)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
        .background(Color(.windowBackgroundColor))
    }
    
    private var modeColor: Color {
        switch selectedMode {
        case .discussion:
            return .blue
        case .qna:
            return .green
        }
    }
    
    private var modePlaceholder: String {
        switch selectedMode {
        case .discussion:
            return "Describe the problem for AI discussion..."
        case .qna:
            return "Ask all AIs a question..."
        }
    }
}

#Preview {
    MessageInputView(inputText: .constant(""), selectedMode: .constant(.discussion)) {
        print("Send")
    }
    .frame(width: 500)
}

