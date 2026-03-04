// BattleLM/Views/History/HistoryDetailView.swift
// Right panel: full conversation viewer matching BattleLM's chat UI style.

import SwiftUI

struct HistoryDetailView: View {
    let entry: CLIHistoryEntry
    @State private var messages: [CLIConversationMessage] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if isLoading {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.title2)
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No messages in this session")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("This session may have ended before any messages were exchanged.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            // Message count header
                            HStack(spacing: 6) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.caption)
                                Text("Messages  \(messages.count)")
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.secondary)

                            ForEach(messages) { msg in
                                HistoryMessageBubble(
                                    message: msg,
                                    aiType: entry.cliType,
                                    containerWidth: geometry.size.width
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .task(id: entry.id) {
            loadConversation()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AILogoView(aiType: entry.cliType, size: 20)
                    Text(projectName)
                        .font(.headline)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text(formattedDate)
                            .font(.caption)
                    }
                    if !shortPath.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text(shortPath)
                                .font(.caption)
                        }
                    }
                }
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var projectName: String {
        if entry.cliType == .claude {
            let comps = entry.project.components(separatedBy: "/")
            if let idx = comps.firstIndex(of: "projects"), idx + 1 < comps.count {
                let encoded = comps[idx + 1]
                return encoded.split(separator: "-").map(String.init).last ?? entry.displayText
            }
        }
        return entry.displayText
    }

    private var shortPath: String {
        if entry.cliType == .claude {
            let comps = entry.project.components(separatedBy: "/")
            if let idx = comps.firstIndex(of: "projects"), idx + 1 < comps.count {
                let encoded = comps[idx + 1]
                let decoded = "/" + encoded.split(separator: "-").joined(separator: "/")
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                return decoded.hasPrefix(home) ? "~" + decoded.dropFirst(home.count) : decoded
            }
        }
        return ""
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d/yyyy, h:mm:ss a"
        return formatter.string(from: entry.timestamp)
    }

    private func loadConversation() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let msgs = CLIHistoryReader.shared.readConversation(entry: entry)
            DispatchQueue.main.async {
                self.messages = msgs
                self.isLoading = false
            }
        }
    }
}

// MARK: - History Message Bubble (matches MessageBubbleView style)

private struct HistoryMessageBubble: View {
    let message: CLIConversationMessage
    let aiType: AIType
    var containerWidth: CGFloat = 500
    @State private var showThinking = false

    private var isUser: Bool { message.role == .user }
    private var maxBubbleWidth: CGFloat { max(containerWidth * 0.7, 200) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Left margin (10%)
            Spacer()
                .frame(width: containerWidth * 0.04)

            // User messages push right
            if isUser {
                Spacer()
            }

            // AI avatar (left side, only for non-user)
            if !isUser {
                AILogoView(aiType: aiType, size: 28)
                    .clipShape(Circle())
                    .frame(width: 28, height: 28)
            }

            // Message content
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Sender name (AI only)
                if !isUser {
                    HStack(spacing: 6) {
                        Text(message.role == .assistant ? aiType.rawValue.capitalized : "Tool")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(message.role == .tool ? .purple : .secondary)

                        // Tool badge
                        if let toolName = message.toolName {
                            Text(toolName)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .foregroundColor(.purple)
                                .cornerRadius(4)
                        }
                    }
                }

                // Thinking toggle
                if let thinking = message.thinking, !thinking.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showThinking.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showThinking ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Thinking")
                                .font(.caption2)
                        }
                        .foregroundColor(.orange)
                    }
                    .buttonStyle(.plain)

                    if showThinking {
                        Text(thinking)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
                            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }

                // Message bubble (matching MessageBubbleView)
                if !message.content.isEmpty {
                    Text(Self.markdownText(message.content))
                        .padding(12)
                        .background(bubbleBackground)
                        .foregroundColor(bubbleTextColor)
                        .cornerRadius(16)
                        .frame(maxWidth: maxBubbleWidth, alignment: isUser ? .trailing : .leading)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.content, forType: .string)
                            } label: {
                                Label("Copy Text", systemImage: "doc.on.doc")
                            }
                        }
                }
            }

            // AI messages push left
            if !isUser {
                Spacer()
            }

            // Right margin (10%)
            Spacer()
                .frame(width: containerWidth * 0.04)
        }
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user: return Color.accentColor
        case .assistant: return Color.gray.opacity(0.12)
        case .tool: return Color.purple.opacity(0.08)
        }
    }

    private var bubbleTextColor: Color {
        isUser ? .white : .primary
    }

    /// Markdown → AttributedString; fallback to plain text
    static func markdownText(_ raw: String) -> AttributedString {
        if let md = try? AttributedString(markdown: raw,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        return AttributedString(raw)
    }
}
