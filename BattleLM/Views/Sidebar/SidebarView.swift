// BattleLM/Views/Sidebar/SidebarView.swift
import SwiftUI

/// Sidebar View
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @State private var addAIHovered: Bool = false
    @State private var createGroupHovered: Bool = false
    
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
                        AIInstanceRow(ai: ai, isSelected: appState.selectedAIId == ai.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                appState.selectAI(ai)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteAI(ai)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
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
                        GroupChatRow(chat: chat, isSelected: appState.selectedGroupChatId == chat.id)
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
            HStack(spacing: 12) {
                Button {
                    appState.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                
                Button {
                    appState.showPairingSheet = true
                } label: {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Device Pairing")
                
                Button {
                    if let url = URL(string: "https://discord.gg/4tnTSg3ZGy") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image("DiscordLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Join our Discord")
                
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

/// Group Chat Row
struct GroupChatRow: View {
    let chat: GroupChat
    var isSelected: Bool = false
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
