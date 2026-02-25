// BattleLM/Views/Chat/SlashCommandMenu.swift
import SwiftUI

/// 快捷指令定义
struct SlashCommand: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
}

/// 快捷指令弹出菜单
struct SlashCommandMenu: View {
    let ai: AIInstance
    let onExecute: (String) -> Void
    
    @State private var isShowingMenu = false
    @State private var isHovered = false
    
    private var commands: [SlashCommand] {
        let statusCommand: SlashCommand
        if ai.type == .gemini {
            statusCommand = SlashCommand(name: "/stats", description: "Show session status", icon: "heart.text.square")
        } else {
            statusCommand = SlashCommand(name: "/status", description: "Show session status", icon: "heart.text.square")
        }
        return [
            SlashCommand(name: "/model", description: "Show current AI model info", icon: "cpu"),
            statusCommand,
            SlashCommand(name: "/clear", description: "Clear chat history", icon: "trash"),
        ]
    }
    
    var body: some View {
        Button {
            isShowingMenu.toggle()
        } label: {
            Text("/")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(isShowingMenu ? .white : .primary.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isShowingMenu ? Color.accentColor : (isHovered ? Color.primary.opacity(0.12) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .background(
            // 点击外部区域关闭菜单
            Group {
                if isShowingMenu {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 10000, height: 10000)
                        .fixedSize()
                        .onTapGesture {
                            isShowingMenu = false
                        }
                }
            }
        )
        .overlay(alignment: .bottomLeading) {
            if isShowingMenu {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        SlashCommandRow(command: command) {
                            isShowingMenu = false
                            onExecute(command.name)
                        }
                        
                        if index < commands.count - 1 {
                            Divider()
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 6)
                .frame(width: 220)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.windowBackgroundColor))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: -2)
                )
                .offset(y: -36)
            }
        }
        .onKeyPress(.escape) {
            if isShowingMenu {
                isShowingMenu = false
                return .handled
            }
            return .ignored
        }
    }
}

/// 单个指令行
private struct SlashCommandRow: View {
    let command: SlashCommand
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: command.icon)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Text(command.description)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
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
