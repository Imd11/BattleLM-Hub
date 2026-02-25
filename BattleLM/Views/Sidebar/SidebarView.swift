// BattleLM/Views/Sidebar/SidebarView.swift
import SwiftUI

/// Sidebar View
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var remoteHost = RemoteHostServer.shared
    @State private var addAIHovered: Bool = false
    @State private var createGroupHovered: Bool = false

    private var pairingHelpText: String {
        let count = remoteHost.connectedDevices.count
        switch count {
        case 0:
            return "Device Pairing"
        case 1:
            return "1 iOS device connected"
        default:
            return "\(count) iOS devices connected"
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Logo
            HStack {
                Image("BattleLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("BattleLM")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Content list
            List {
                // AI instances section
                Section("AI Instances") {
                    ForEach(appState.aiInstances) { ai in
                        AIInstanceRow(ai: ai, isSelected: appState.selectedAIId == ai.id) {
                            deleteAI(ai)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectAI(ai)
                        }
                    }
                    
                    Button {
                        appState.showAddAISheet = true
                    } label: {
                        Label("Add AI", systemImage: "plus.circle")
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(addAIHovered ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        addAIHovered = hovering
                    }
                }
                
                // Group chats section
                Section("Group Chats") {
                    ForEach(appState.groupChats) { chat in
                        GroupChatRow(chat: chat, isSelected: appState.selectedGroupChatId == chat.id) {
                            appState.removeGroupChat(chat)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            appState.selectedGroupChatId = chat.id
                            appState.selectedAIId = nil  // Clear AI selection
                        }
                    }
                    
                    Button {
                        appState.showCreateGroupSheet = true
                    } label: {
                        Label("Create Group", systemImage: "plus.circle")
                            .foregroundColor(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(createGroupHovered ? Color.accentColor.opacity(0.1) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        createGroupHovered = hovering
                    }
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            
            // Bottom settings
            HStack(spacing: 4) {
                SidebarIconButton(icon: "gearshape.fill", help: "Settings (⌘,)") {
                    appState.showSettingsSheet = true
                }
                
                SidebarIconButton(icon: "iphone.radiowaves.left.and.right", help: pairingHelpText, showFastHoverHelp: true) {
                    appState.showPairingSheet = true
                }
                
                SidebarIconButton(customImage: "DiscordLogo", help: "Join our Discord") {
                    if let url = URL(string: "https://discord.gg/4tnTSg3ZGy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                
                Spacer()
            }
            .padding()
        }
        .background(Color(.windowBackgroundColor))
    }
    
    /// Delete AI instance
    private func deleteAI(_ ai: AIInstance) {
        Task {
            // Stop session first
            if ai.isActive {
                try? await SessionManager.shared.stopSession(for: ai)
            }
            // Remove from appState
            await MainActor.run {
                appState.removeAI(ai)
            }
        }
    }
}

/// AI Instance Row
struct AIInstanceRow: View {
    let ai: AIInstance
    var isSelected: Bool = false
    let onDelete: () -> Void
    @State private var isHovered: Bool = false
    @ObservedObject private var sessionManager = SessionManager.shared

    private var isSessionRunning: Bool {
        sessionManager.sessionStatus[ai.id] == .running
    }
    
    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            Circle()
                .fill(isSessionRunning ? .green : .gray)
                .frame(width: 8, height: 8)
            
            // AI Logo
            AILogoView(aiType: ai.type, size: 18)
            
            // Name and path
            VStack(alignment: .leading, spacing: 2) {
                Text(ai.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                Text(ai.shortPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Elimination mark
            if ai.isEliminated {
                Text("OUT")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.2))
                    .cornerRadius(4)
            }
            
            // Three-dots menu (visible on hover)
            Menu {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.1))
                    )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// Group Chat Row
struct GroupChatRow: View {
    let chat: GroupChat
    var isSelected: Bool = false
    let onDelete: () -> Void
    @EnvironmentObject var appState: AppState
    @State private var isHovered: Bool = false
    
    var body: some View {
        HStack(spacing: 10) {
            // Mode icon (moved to left, enlarged)
            Image(systemName: chat.mode.iconName)
                .font(.title3)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name)
                    .fontWeight(isSelected ? .semibold : .medium)
                
                // Member avatars
                HStack(spacing: -6) {
                    ForEach(chat.memberIds.prefix(3), id: \.self) { memberId in
                        if let ai = appState.aiInstance(for: memberId) {
                            ZStack {
                                Circle()
                                    .fill(Color(.windowBackgroundColor))
                                    .frame(width: 16, height: 16)
                                AILogoView(aiType: ai.type, size: 12)
                            }
                            .overlay(
                                Circle()
                                    .stroke(Color(.windowBackgroundColor), lineWidth: 1)
                            )
                        }
                    }
                    
                    if chat.memberIds.count > 3 {
                        Text("+\(chat.memberIds.count - 3)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Three-dots menu (visible on hover)
            Menu {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .opacity(isHovered ? 1 : 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

#Preview {
    SidebarView()
        .environmentObject(AppState())
        .frame(width: 250)
}

/// Sidebar 底部图标按钮 - 带 hover 效果
private struct SidebarIconButton: View {
    var icon: String? = nil
    var customImage: String? = nil
    let help: String
    var showFastHoverHelp: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var showQuickHelp = false
    @State private var quickHelpWorkItem: DispatchWorkItem?
    
    var body: some View {
        Button(action: action) {
            Group {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                } else if let customImage = customImage {
                    Image(customImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 28, height: 28)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            handleHoverChange(hovering)
        }
        .onDisappear {
            quickHelpWorkItem?.cancel()
        }
        .help(help)
        .overlay(alignment: .top) {
            if showFastHoverHelp && showQuickHelp {
                Text(help)
                    .font(.caption2)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(.controlBackgroundColor))
                            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
                    )
                    .offset(y: -34)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleHoverChange(_ hovering: Bool) {
        quickHelpWorkItem?.cancel()

        guard showFastHoverHelp else {
            if showQuickHelp {
                withAnimation(.easeOut(duration: 0.08)) {
                    showQuickHelp = false
                }
            }
            return
        }

        if hovering {
            let work = DispatchWorkItem {
                withAnimation(.easeOut(duration: 0.12)) {
                    showQuickHelp = true
                }
            }
            quickHelpWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        } else {
            withAnimation(.easeOut(duration: 0.08)) {
                showQuickHelp = false
            }
        }
    }
}
