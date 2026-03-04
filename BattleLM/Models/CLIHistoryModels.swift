// BattleLM/Models/CLIHistoryModels.swift
// Data models for CLI conversation history.

import Foundation

/// A single entry in the CLI history index (one per user message).
struct CLIHistoryEntry: Identifiable, Hashable {
    let id: String          // sessionId
    let cliType: AIType     // .claude / .codex / .gemini
    let displayText: String // first user message preview
    let timestamp: Date
    let project: String     // working directory

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: CLIHistoryEntry, rhs: CLIHistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// A single message in a full conversation transcript.
struct CLIConversationMessage: Identifiable {
    let id: String
    let role: MessageRole
    let content: String
    let thinking: String?
    let toolName: String?
    let timestamp: Date?

    enum MessageRole: String {
        case user
        case assistant
        case tool
    }
}

/// Grouped history entries by date for UI display.
struct CLIHistoryGroup: Identifiable {
    let id: String  // group label
    let label: String
    let entries: [CLIHistoryEntry]
}
